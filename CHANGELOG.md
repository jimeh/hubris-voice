# Changelog

## [0.1.1](https://github.com/jimeh/hubris-voice/compare/v0.1.0...v0.1.1) (2026-09-13)


### Bug Fixes

* **build:** release build and move release automation to SwiftPM ([#6](https://github.com/jimeh/hubris-voice/issues/6)) ([b722108](https://github.com/jimeh/hubris-voice/commit/b7221084fda920d64e41b9618daa11bc8aaa547c))

## 0.1.0 (2026-09-13)


### Features

* add a shortcut recorder to Settings ([6afe38b](https://github.com/jimeh/hubris-voice/commit/6afe38b6e8cecb3eb8f290452d94d3de316c58c6))
* build out daily-use dictation, settings, and recovery ([228bbf4](https://github.com/jimeh/hubris-voice/commit/228bbf4c908c84afb56140bbf7164e3d1b4aae9c))
* configurable shortcuts, tap to lock, and paste last transcript ([f0ae3f5](https://github.com/jimeh/hubris-voice/commit/f0ae3f5c645fb5c203ae265471ce6eedfd084617))
* confirm insertion by content and add keyboard recovery ([ea990ec](https://github.com/jimeh/hubris-voice/commit/ea990ecaaa43402a195caacbe3e6aea1712bcefa))
* establish working macOS dictation proof of concept ([4155415](https://github.com/jimeh/hubris-voice/commit/4155415f43ae66bb301352f9ab0097683a4ce315))
* expand the menu bar and add a History tab ([74975f2](https://github.com/jimeh/hubris-voice/commit/74975f29175a2361e942d0878733cafb719b8113))
* insert at the current focus, hide on attempted, and add an overlay line cap ([542c42e](https://github.com/jimeh/hubris-voice/commit/542c42ea97846368a83b89cf2f62350108cffaa5))
* insert directly through Accessibility when the field allows it ([0c4c17f](https://github.com/jimeh/hubris-voice/commit/0c4c17fa187a0480ebf695920729481606cdd08c))
* keep a transcript history with outcomes and sound cues ([fbe63e6](https://github.com/jimeh/hubris-voice/commit/fbe63e668b5f2627a660597e65d0a0ed9151e1ee))
* make dictation resilient with a core session state machine ([894beea](https://github.com/jimeh/hubris-voice/commit/894beea3b17a8638084b1d987744908d24344129))
* make paste fallback safe for Electron apps ([4257d56](https://github.com/jimeh/hubris-voice/commit/4257d560e995e7258cbc77d09f826897514719c9))
* persist settings on change and update the live session ([13545a8](https://github.com/jimeh/hubris-voice/commit/13545a8e0d8705c8ee259d7284c8a7ed3c7a0354))
* place the overlay relative to the dictated field ([ba1bcae](https://github.com/jimeh/hubris-voice/commit/ba1bcaea9262e27396335440eda44af7a7a231aa))
* publish signed macOS releases ([#3](https://github.com/jimeh/hubris-voice/issues/3)) ([c148a87](https://github.com/jimeh/hubris-voice/commit/c148a87f624cfb98dbcb665ac85bf904cd604ba0))
* replace the overlay with a pill showing only the transcript and mic level ([dcf6e48](https://github.com/jimeh/hubris-voice/commit/dcf6e48216f74a3b0802a33c0dab8cff29536c50))
* restructure Settings into a tabbed window ([ec34dd7](https://github.com/jimeh/hubris-voice/commit/ec34dd7dd55c49995a5d2f0f49929276f9ea8a47))


### Bug Fixes

* activate the app when opening Settings from the menu bar ([363ef23](https://github.com/jimeh/hubris-voice/commit/363ef23eed6f2ecc2dcb8b84363f9db6fb8eff0a))
* do not lay out the hidden pill from inside the app graph update ([0ed45b0](https://github.com/jimeh/hubris-voice/commit/0ed45b0e516624a198728ffe356f49bbd37bda1c))
* harden release shell tooling ([#5](https://github.com/jimeh/hubris-voice/issues/5)) ([1d0ea39](https://github.com/jimeh/hubris-voice/commit/1d0ea3940ec93acc283976530f26e2a9dcddfb7b))
* isolate dictation sessions and preserve insertion recovery ([b3157ad](https://github.com/jimeh/hubris-voice/commit/b3157ad2bdaa98945f6067f43ffa40928b4aed80))
* keep multiline transcript previews consistently left aligned ([684156a](https://github.com/jimeh/hubris-voice/commit/684156a71eda2c52ed803bf3b9b97fa5fbce5ab8))
* omit the recovery hint when there is no transcript to recover ([b4f4a30](https://github.com/jimeh/hubris-voice/commit/b4f4a30f589de6aba9a969b9d357b019d1ed8ecf))
* preserve rejected partial transcripts in recovery history ([bc37cc9](https://github.com/jimeh/hubris-voice/commit/bc37cc9f01d0dbe0b92df311f99345e0a30c7701))
* recover rejected audio commits without disrupting later dictation ([d4296f7](https://github.com/jimeh/hubris-voice/commit/d4296f724a10ec5e9c08afd0dd55b3daa133d6b6))
* reject retired transcript items and defer offline settings updates ([7bfd982](https://github.com/jimeh/hubris-voice/commit/7bfd982aa662c7f1be405e80ea290c790b86fcf6))
* restore live transcript preview while recording ([b3718e6](https://github.com/jimeh/hubris-voice/commit/b3718e68fe3c4bf978891cdac8d4110a1ad5d05d))
* serialize clipboard insertion requests ([79d5818](https://github.com/jimeh/hubris-voice/commit/79d581809163bff555d236ede5eedaf284d162bc))
* stabilize dictation overlay and development identity ([83d7173](https://github.com/jimeh/hubris-voice/commit/83d7173b8fcab554f940dd74385f8ffdee20e16e))
* use transient clipboard paste for reliable dictation insertion ([1b39125](https://github.com/jimeh/hubris-voice/commit/1b39125d3369d0b2c0d507650d3f85fe41ea74ad))

## Changelog
