local test = require("test")
local http_client = require("http_client")
local json = require("json")
local sql = require("sql")
local time = require("time")
local user_repo = require("user_repo")

-- The login endpoint of the test app (app:gateway, app:api.public).
local TOKEN_URL = "http://localhost:19087/api/public/user/token"

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

-- Signs in over HTTP and returns the actor metadata of the new token.
local function login(email, password, user_agent)
    local response, err
    -- The gateway may still be starting: retry a failed connection for 10 s.
    for _ = 1, 50 do
        response, err = http_client.post(TOKEN_URL, {
            headers = {
                ["Content-Type"] = "application/json",
                ["User-Agent"] = user_agent,
            },
            body = json.encode({ email = email, password = password }),
            timeout = "10s",
        })
        if response then break end
        time.sleep("200ms")
    end
    test.is_nil(err)
    test.eq(response.status_code, 200, tostring(response.body))
    local body = json.decode(response.body)
    return body.actor.metadata
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

        test.it("keeps the facts of a login under session", function()
            local metadata = login(email, password, "browser-one")
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
        test.it("gives two logins of one user the same metadata outside session", function()
            local first = login(email, password, "browser-one")
            local second = login(email, password, "browser-two")
            test.is_true(same(without_session(first), without_session(second)),
                json.encode({ first = first, second = second }))
            test.neq((first.session or {}).user_agent, (second.session or {}).user_agent)
        end)
    end)
end

return test.run_cases(define_tests)
