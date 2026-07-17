# Changelog

## [0.5.0](https://github.com/wippyai/userspace/compare/v0.4.0...v0.5.0) (2026-07-17)


### Features

* **docker:** OCI runtime passthrough + adopt running same-name containers ([616a151](https://github.com/wippyai/userspace/commit/616a151bbe73c7ea1418792ed621995848ebebeb))
* **docker:** OCI runtime passthrough + adopt running same-name containers ([9fe25af](https://github.com/wippyai/userspace/commit/9fe25af845a8e68418b078847894819c85f2e512))

## [0.4.0](https://github.com/wippyai/userspace/compare/v0.3.13...v0.4.0) (2026-07-09)


### Features

* Add `eml` mime type ([#9](https://github.com/wippyai/userspace/issues/9)) ([2920f55](https://github.com/wippyai/userspace/commit/2920f552923fd5ab44fb5363052f56d1d524ed55))
* Add initial implementation ([aca4456](https://github.com/wippyai/userspace/commit/aca4456a5371b7910dfb38cb747cb8c03a9c2290))
* **ci:** adopt release-please for automated releases ([#47](https://github.com/wippyai/userspace/issues/47)) ([4519baf](https://github.com/wippyai/userspace/commit/4519baf29ff71a84e983342c2c7efbcb9bf96b79))
* **dataflow:** update 2 ([#6](https://github.com/wippyai/userspace/issues/6)) ([be0683e](https://github.com/wippyai/userspace/commit/be0683e58c6d2b3f4671ffd9efde3b1929ed6163))
* Define new param `web_host_origin_env` ([214e897](https://github.com/wippyai/userspace/commit/214e89739ec4bdaad15a357c78a34978c48814b6))
* Update Dataflow ([#3](https://github.com/wippyai/userspace/issues/3)) ([7032126](https://github.com/wippyai/userspace/commit/7032126ea557177d30a284ca97c9079a40772acd))


### Bug Fixes

* **api:** sanitize error responses across all userspace HTTP handlers ([99058ba](https://github.com/wippyai/userspace/commit/99058baa3971d7a2cbba24a39030df3d2d4403fb))
* **api:** stop leaking raw errors in userspace API responses ([d2c2af3](https://github.com/wippyai/userspace/commit/d2c2af36963242558993b3e51dc74859251260fe))
* **api:** stop leaking raw errors in userspace API responses ([790f0f9](https://github.com/wippyai/userspace/commit/790f0f9851b3ed6d2aa791f6832e79c5d79f061e))
* deduplicate user migrations ([9d3e628](https://github.com/wippyai/userspace/commit/9d3e628fc9a5387c9380ab54a4008ecc78fa2c25))
* Fix `create_extraction_group` tool schema ([#7](https://github.com/wippyai/userspace/issues/7)) ([7784e04](https://github.com/wippyai/userspace/commit/7784e044929d0befc8048cd1f45d05c5c12bba16))
* Fix timestamps for PostgreSQL ([#11](https://github.com/wippyai/userspace/issues/11)) ([7609305](https://github.com/wippyai/userspace/commit/7609305cbc2bc7f8682db350657c15c359cab20c))
* Fix users table name in migrations ([#10](https://github.com/wippyai/userspace/issues/10)) ([740f326](https://github.com/wippyai/userspace/commit/740f32686213d574bf265169777ba9669d57c22e))
* fix vendor name ([227fe28](https://github.com/wippyai/userspace/commit/227fe28315a41637a57aa1fc143b643349c0128b))
* **uploads:** drop stale hardcoded module version ([85afc0f](https://github.com/wippyai/userspace/commit/85afc0fa5a9a8200aa11b813683eeb042f66c363))
* **uploads:** replace hardcoded S3 ID with dynamic retrieval ([#45](https://github.com/wippyai/userspace/issues/45)) ([ebb214b](https://github.com/wippyai/userspace/commit/ebb214b1ef208da16eea8068b2b9314c3beb116c))
