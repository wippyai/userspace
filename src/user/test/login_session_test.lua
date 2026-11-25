local test = require("test")
local http_client = require("http_client")
local json = require("json")
local security = require("security")
local sql = require("sql")
local time = require("time")
local user_repo = require("user_repo")

-- The test app's gateway (app:gateway): public and token-authenticated routers.
local BASE_URL = "http://localhost:19087"
local TOKEN_STORE = "userspace.user.security:tokens"

-- `wippy test` starts the test app's services together with the suites, so
-- the users migrations may still be running. Waits up to 30 s.
local function wait_for_users_table()
    for _ = 1, 150 do
        local db = sql.get("app:db")
        local rows = db and db:query("SELECT 1 FROM app_users LIMIT 1")
        if db then db:release() end
        if rows then return end
        time.sleep("200ms")
    end
    error("the app_users table did not appear within 30 s")
end

-- Deep equality of two JSON-shaped values.
local function same(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do
        if not same(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function without_session(metadata)
    local out = {}
    for key, value in pairs(metadata) do
        if key ~= "session" then out[key] = value end
    end
    return out
end

-- Sends one request and returns the response; the gateway may still be
-- starting, so a failed connection is retried for 10 s.
local function send(method, path, options)
    local response, err
    for _ = 1, 50 do
        if method == "POST" then
            response, err = http_client.post(BASE_URL .. path, options)
        else
            response, err = http_client.get(BASE_URL .. path, options)
        end
        if response then break end
        time.sleep("200ms")
    end
    test.is_nil(err)
    return response
end

-- Sends one request that must succeed and returns the decoded body.
local function request(method, path, options)
    local response = send(method, path, options)
    test.eq(response.status_code, 200, tostring(response.body))
    return json.decode(response.body)
end

-- Signs in over HTTP and returns the response body.
local function login(email, password, user_agent, metadata)
    return request("POST", "/api/public/user/token", {
        headers = {
            ["Content-Type"] = "application/json",
            ["User-Agent"] = user_agent,
        },
        body = json.encode({ email = email, password = password, metadata = metadata }),
        timeout = "10s",
    })
end

-- The actor metadata stored in a token, which is what wippy/relay compares.
local function token_metadata(token)
    local store, store_err = security.token_store(TOKEN_STORE)
    test.is_nil(store_err)
    local actor, _, err = store:validate(token)
    store:close()
    test.is_nil(err)
    return actor:meta()
end

local function me(token)
    return request("GET", "/api/user/me", {
        headers = { Authorization = "Bearer " .. token },
        timeout = "10s",
    })
end

local function define_tests()
    local user_id = "login_session_test_user"
    local email = "login.session@example.com"
    local password = "testpass123"

    test.describe("login actor metadata", function()
        test.before_all(function()
            wait_for_users_table()
            local _, err = user_repo.create({
                user_id = user_id,
                email = email,
                password = password,
                full_name = "Login Session",
            })
            if err then error(err) end
        end)

        test.after_all(function()
            pcall(function()
                local db = sql.get("app:db")
                db:execute("DELETE FROM app_users WHERE user_id = ?", { user_id })
                db:release()
            end)
        end)

        test.it("keeps the facts of a login under session in the token", function()
            local metadata = token_metadata(login(email, password, "browser-one").token)
            test.eq(type(metadata.session), "table", json.encode(metadata))
            test.eq(metadata.session.user_agent, "browser-one")
            test.not_nil(metadata.session.login_time)
            test.not_nil(metadata.session.ip_address)
            test.is_nil(metadata.login_time)
            test.is_nil(metadata.ip_address)
            test.is_nil(metadata.user_agent)
        end)

        -- wippy/relay compares a user's actor metadata, except `session`, to
        -- decide whether a connection may join the user's current hub. Two
        -- logins of one user with the same groups must compare equal, or the
        -- second login retires the hub that runs the first login's sessions.
        test.it("gives two logins of one user the same token metadata outside session", function()
            local first = token_metadata(login(email, password, "browser-one", { device = "phone" }).token)
            local second = token_metadata(login(email, password, "browser-two", { device = "desktop" }).token)
            test.is_true(same(without_session(first), without_session(second)),
                json.encode({ first = first, second = second }))
            test.neq((first.session or {}).user_agent, (second.session or {}).user_agent)
            test.eq(first.session.client.device, "phone")
            test.eq(second.session.client.device, "desktop")
        end)

        -- Other modules read the top level as the user's authority (for example
        -- component access reads `groups`), so no client value may reach it.
        test.it("keeps the client's metadata as session.client and never at the top level", function()
            local body = login(email, password, "browser-one", {
                user_id = "another-user",
                email = "another@example.com",
                full_name = { first = "Forged" },
                status = "inactive",
                security_groups = { "app.security:admin" },
                groups = { "another-user" },
                login_time = "1999-01-01T00:00:00Z",
                user_agent = "client-claim",
                session = { user_agent = "client-claim" },
                team = "blue",
            })
            local metadata = token_metadata(body.token)
            local top_level = { user_id = true, email = true, full_name = true, status = true,
                security_groups = true, session = true }
            for key in pairs(metadata) do
                test.is_true(top_level[key] == true, "client key at the top level: " .. tostring(key))
            end
            test.eq(metadata.user_id, user_id)
            test.eq(metadata.email, email)
            test.eq(metadata.full_name, "Login Session")
            test.eq(metadata.status, "active")
            test.eq(#(metadata.security_groups or {}), 0)
            test.eq(metadata.session.user_agent, "browser-one")
            test.neq(metadata.session.login_time, "1999-01-01T00:00:00Z")
            test.eq(metadata.session.client.team, "blue")
            test.eq(metadata.session.client.groups[1], "another-user")

            local profile = me(body.token)
            test.eq(profile.user.email, email)
            test.eq(profile.user.full_name, "Login Session")
            test.eq(profile.user.status, "active")
            test.is_nil(profile.user.metadata.groups)
            test.eq(profile.session.user_agent, "browser-one")
        end)

        test.it("answers 400 when metadata is not a JSON object", function()
            local credentials = '"email":' .. json.encode(email) .. ',"password":' .. json.encode(password)
            for _, metadata in ipairs({ "true", "42", '"phone"', "[1,2]" }) do
                local response = send("POST", "/api/public/user/token", {
                    headers = { ["Content-Type"] = "application/json" },
                    body = "{" .. credentials .. ',"metadata":' .. metadata .. "}",
                    timeout = "10s",
                })
                test.eq(response.status_code, 400, metadata .. ": " .. tostring(response.body))
                test.eq(json.decode(response.body).error, "Invalid metadata field", metadata)
            end

            -- JSON null, an empty object and an empty array (which decode alike)
            -- are the same as no metadata.
            for _, empty in ipairs({ "null", "{}", "[]" }) do
                local response = send("POST", "/api/public/user/token", {
                    headers = { ["Content-Type"] = "application/json" },
                    body = "{" .. credentials .. ',"metadata":' .. empty .. "}",
                    timeout = "10s",
                })
                test.eq(response.status_code, 200, empty .. ": " .. tostring(response.body))
                local metadata = token_metadata(json.decode(response.body).token)
                test.is_nil(metadata.session.client, empty)
            end
        end)

        test.it("keeps the login facts at the top level of the login and /user/me responses", function()
            local body = login(email, password, "browser-one")
            test.eq(body.actor.metadata.user_agent, "browser-one")
            test.not_nil(body.actor.metadata.login_time)
            test.not_nil(body.actor.metadata.ip_address)
            test.eq(body.actor.metadata.session.user_agent, "browser-one")

            local profile = me(body.token)
            test.eq(profile.user.metadata.user_agent, "browser-one")
            test.not_nil(profile.user.metadata.login_time)
            test.eq(profile.session.user_agent, "browser-one")
            test.eq(profile.session.login_time, body.actor.metadata.login_time)
        end)

        -- Before the login facts moved under `session`, a client could add a
        -- `session` table next to the server's top-level facts, so the
        -- top-level value wins and each fact is read separately.
        test.it("reads each login fact of an older token separately in /user/me", function()
            local store, store_err = security.token_store(TOKEN_STORE)
            test.is_nil(store_err)
            local scope, scope_err = security.named_scope("app.security:user")
            test.is_nil(scope_err)
            local actor = security.new_actor(user_id, {
                user_id = user_id,
                email = email,
                login_time = "2026-01-01T00:00:00Z",
                user_agent = "legacy-browser",
                session = { device = "phone", user_agent = { device = "phone" }, ip_address = "10.0.0.9" },
            })
            local token, create_err = store:create(actor, scope, { expiration = "1h" })
            store:close()
            test.is_nil(create_err)

            local profile = me(token)
            test.eq(profile.session.login_time, "2026-01-01T00:00:00Z")
            test.eq(profile.session.ip_address, "10.0.0.9")
            test.eq(profile.session.user_agent, "legacy-browser")
            test.eq(profile.user.metadata.user_agent, "legacy-browser")
            test.eq(profile.user.metadata.session.device, "phone")
        end)
    end)
end

return test.run_cases(define_tests)
