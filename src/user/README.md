# userspace/user

User management and security tokens.

## Features

- User constants and configuration
- Security token generation
- User traits and persistence

## Actor metadata of a login token

The top level of a token's actor metadata holds only the user from the user record (`user_id`, `email`, `full_name`, `status`, `security_groups`) and the `session` key. Other modules read the top level as the user's authority. Everything that belongs to one login is under `session`: the server's facts (`login_time`, `ip_address`, `user_agent`) and, as one value `session.client`, the `metadata` object the client sent in the login request. `metadata` must be a JSON object (otherwise the login answers 400); an empty object or array counts as none. Client values never reach the top level.

wippy/relay compares all actor metadata except `session` to decide whether a connection may join the user's relay hub, so values that change with every login must stay under `session`. Code that reads `actor:meta().login_time`, `ip_address` or `user_agent` directly must read them from `actor:meta().session` instead; tokens issued before this change still have them at the top level. The HTTP responses of `/user/token` (`actor.metadata`) and `/user/me` (`user.metadata`) still carry the three facts at the top level as well.
