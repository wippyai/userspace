# userspace/user

User management and security tokens.

## Features

- User constants and configuration
- Security token generation
- User traits and persistence

## Actor metadata of a login token

A token's actor metadata holds the user (`user_id`, `email`, `full_name`, `status`, `security_groups`) and any keys the client sent in the `metadata` field of the login request. The facts of one login (`login_time`, `ip_address`, `user_agent`) are under the `session` key. The server sets them and a client cannot replace them; a client `session` table only adds other fields under `session`.

wippy/relay compares all actor metadata except `session` to decide whether a connection may join the user's relay hub, so values that change with every login must stay under `session`. Code that reads `actor:meta().login_time`, `ip_address` or `user_agent` directly must read them from `actor:meta().session` instead; tokens issued before this change still have them at the top level. The HTTP responses of `/user/token` (`actor.metadata`) and `/user/me` (`user.metadata`) still carry the three facts at the top level as well.
