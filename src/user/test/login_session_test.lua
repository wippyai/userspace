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

-- Sends one request; the gateway may still be starting, so a failed
-- connection is retried for 10 s.
local function request(method, path, options)
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
            local first = token_metadata(login(email, password, "browser-one").token)
            local second = token_metadata(login(email, password, "browser-two").token)
            test.is_true(same(without_session(first), without_session(second)),
                json.encode({ first = first, second = second }))
            test.neq((first.session or {}).user_agent, (second.session or {}).user_agent)
        end)

        test.it("keeps the server's login facts when the client sends a session table", function()
            local emptied = token_metadata(login(email, password, "browser-one", { session = {} }).token)
            test.eq(type(emptied.session), "table", json.encode(emptied))
            test.eq(emptied.session.user_agent, "browser-one")
            test.not_nil(emptied.session.login_time)
            test.not_nil(emptied.session.ip_address)

            local spoofed = token_metadata(login(email, password, "browser-one", {
                session = { device = "phone", user_agent = "spoofed", login_time = "1999-01-01T00:00:00Z" },
            }).token)
            test.eq(type(spoofed.session), "table", json.encode(spoofed))
            test.eq(spoofed.session.device, "phone")
            test.eq(spoofed.session.user_agent, "browser-one")
            test.neq(spoofed.session.login_time, "1999-01-01T00:00:00Z")
        end)

        test.it("keeps client login fact keys out of the top level of the token", function()
            local first = token_metadata(login(email, password, "browser-one", {
                team = "blue", user_agent = "client-a", ip_address = "10.0.0.1", login_time = "2001-01-01T00:00:00Z",
            }).token)
            local second = token_metadata(login(email, password, "browser-two", {
                team = "blue", user_agent = "client-b", ip_address = "10.0.0.2", login_time = "2002-01-01T00:00:00Z",
            }).token)
            test.eq(first.team, "blue")
            test.is_nil(first.user_agent)
            test.is_nil(first.ip_address)
            test.is_nil(first.login_time)
            test.is_true(same(without_session(first), without_session(second)),
                json.encode({ first = first, second = second }))
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
        -- `session` table next to the top-level facts.
        test.it("reads each login fact of an older token separately in /user/me", function()
            local store, store_err = security.token_store(TOKEN_STORE)
            test.is_nil(store_err)
            local scope, scope_err = security.named_scope("app.security:user")
            test.is_nil(scope_err)
            local actor = security.new_actor(user_id, {
                user_id = user_id,
                email = email,
                login_time = "2026-01-01T00:00:00Z",
                ip_address = "10.0.0.9",
                user_agent = "legacy-browser",
                session = { device = "phone" },
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
