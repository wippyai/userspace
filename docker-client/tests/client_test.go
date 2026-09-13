// SPDX-License-Identifier: Apache-2.0
package client_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestStandaloneClientInspectStatus(t *testing.T) {
	binary := os.Getenv("WIPPY")
	if binary == "" {
		t.Fatal("WIPPY must select the runtime executable")
	}
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate client package")
	}
	component := filepath.Dir(filepath.Dir(file))
	root := t.TempDir()
	socket := filepath.Join(root, "docker.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	calls := map[string]int{}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls[r.Method+" "+r.URL.Path]++
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/_ping":
			fmt.Fprint(w, `{}`)
		case "/containers/found/json":
			fmt.Fprint(w, `{"Id":"found"}`)
		case "/containers/missing/json":
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprint(w, `{"message":"No such container"}`)
		case "/containers/broken/json":
			connection, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			connection.Close()
		default:
			t.Errorf("unexpected Docker request: %s %s", r.Method, r.URL.Path)
			http.Error(w, "unexpected request", http.StatusForbidden)
		}
	})}
	go server.Serve(listener)
	defer server.Close()
	quotedSocket, _ := json.Marshal(socket)
	quotedComponent, _ := json.Marshal(component)
	manifest := `version: '1.0'
namespace: probe
entries:
- name: dependency
  kind: ns.dependency
  component: userspace/docker-client
  version: 0.1.0
- name: terminal
  kind: terminal.host
  hide_logs: true
  lifecycle: {auto_start: true}
- name: check
  kind: process.lua
  source: file://check.lua
  method: main
  imports: {client: 'userspace.docker:docker_client'}
  meta:
    command:
      name: check
      security:
        actor: {id: fixture}
        policies: [probe:socket, probe:requests]
- name: socket
  kind: security.policy
  policy: {actions: [http_client.unix_socket], resources: [SOCKET], effect: allow}
- name: requests
  kind: security.policy
  policy: {actions: [http_client.request], resources: ['http://docker/*'], effect: allow}
`
	script := `local client = require("client")
local function main()
    local docker, connection_error = client.new(SOCKET)
    assert(docker, tostring(connection_error))
    local found, found_error, found_status = docker:inspect_container("found")
    assert(found and found.Id == "found" and not found_error and found_status == 200)
    local missing, missing_error, missing_status = docker:inspect_container("missing")
    assert(not missing and missing_error and missing_status == 404)
    local broken, broken_error, broken_status = docker:inspect_container("broken")
    assert(not broken and broken_error and broken_status == nil)
    return true
end
return {main=main}
`
	files := map[string]string{
		"src/_index.yaml": strings.ReplaceAll(manifest, "SOCKET", string(quotedSocket)),
		"src/check.lua":   strings.ReplaceAll(script, "SOCKET", string(quotedSocket)),
		"wippy.lock":      "directories:\n  src: src\n  modules: .wippy\n",
		".wippy.yaml":     "version: '1.0'\nworkspace:\n  replacements:\n    userspace/docker-client: " + string(quotedComponent) + "\n",
	}
	for path, content := range files {
		path = filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, binary, "run", "check")
	command.Dir = root
	command.Env = []string{"HOME=" + root, "PATH=/usr/bin:/bin"}
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("client boundary: %v\n%s", err, output)
	}
	mu.Lock()
	defer mu.Unlock()
	for _, path := range []string{"found", "missing", "broken"} {
		if calls["GET /containers/"+path+"/json"] == 0 {
			t.Errorf("missing actual %s request", path)
		}
	}
}
