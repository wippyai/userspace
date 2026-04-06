local test = require("test")
local user_repo = require("user_repo")
local user_groups_repo = require("user_groups_repo")

local function define_tests()
    local test_user_id = "email_case_test_user"

    test.describe("email case insensitivity", function()

        test.after_all(function()
            pcall(function()
                local db = require("sql").get("app:db")
                db:execute("DELETE FROM app_users WHERE user_id = ?", { test_user_id })
                db:release()
            end)
        end)

        test.it("stores email as lowercase on create", function()
            local result, err = user_repo.create({
                user_id = test_user_id,
                email = "Test.User@Example.COM",
                password = "testpass123",
                full_name = "Test User",
            })
            test.is_nil(err)
            test.not_nil(result)
            test.eq(result.email, "test.user@example.com")
        end)

        test.it("finds user by lowercase email", function()
            local user, err = user_repo.get("test.user@example.com")
            test.is_nil(err)
            test.not_nil(user)
            test.eq(user.user_id, test_user_id)
        end)

        test.it("finds user by mixed case email", function()
            local user, err = user_repo.get("Test.User@Example.COM")
            test.is_nil(err)
            test.not_nil(user)
            test.eq(user.user_id, test_user_id)
        end)

        test.it("finds user by uppercase email", function()
            local user, err = user_repo.get("TEST.USER@EXAMPLE.COM")
            test.is_nil(err)
            test.not_nil(user)
            test.eq(user.user_id, test_user_id)
        end)

        test.it("verifies password with mixed case email", function()
            local valid = user_repo.verify_password("Test.User@EXAMPLE.com", "testpass123")
            test.is_true(valid)
        end)

        test.it("get_user_with_groups works with mixed case", function()
            local user, err = user_groups_repo.get_user_with_groups("TEST.USER@example.COM")
            test.is_nil(err)
            test.not_nil(user)
            test.eq(user.user_id, test_user_id)
        end)

        test.it("rejects duplicate with different case", function()
            local _, err = user_repo.create({
                user_id = "email_case_test_dupe",
                email = "TEST.USER@EXAMPLE.COM",
                password = "otherpass123",
            })
            test.not_nil(err)
        end)
    end)
end

return test.run_cases(define_tests)
