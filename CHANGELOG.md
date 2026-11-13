# Changelog

## [0.8.0](https://github.com/Vibrant-Planet-Open-Science/fvs-build/compare/v0.7.2...v0.8.0) (2026-11-13)


### ⚠ BREAKING CHANGES

* rename the GUI image to fvs-workspace ([#69](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/69))
* pin native toolchains and unify bundle names ([#67](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/67))
* assemble native bundles in the build job ([#66](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/66))

### Features

* ship the FVS executables, fvs2py and an R kernel in the GUI image ([#64](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/64)) ([216d633](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/216d633f89774052188f0c453f012fcb73dfef33))


### Code Refactoring

* assemble native bundles in the build job ([#66](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/66)) ([464ef56](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/464ef56c357c14f8cbf5f6568799c668b54437ae))
* pin native toolchains and unify bundle names ([#67](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/67)) ([1ed45ba](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/1ed45ba911be5f2c5726baba7dd4e6b3a3cac575))
* rename the GUI image to fvs-workspace ([#69](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/69)) ([20e1f8b](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/20e1f8bfdac2e811006efb61ffa081f374584d84))

## [0.7.2](https://github.com/Vibrant-Planet-Open-Science/fvs-build/compare/v0.7.1...v0.7.2) (2026-11-13)


### Features

* record file checksums and component licenses in the native bundle SBOMs ([#62](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/62)) ([f463686](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/f463686eb7dd16e165ce00f7f1a1c584401445f3))

## [0.7.1](https://github.com/Vibrant-Planet-Open-Science/fvs-build/compare/v0.7.0...v0.7.1) (2026-11-13)


### Features

* build FVS 2027.1.0 by default ([#56](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/56)) ([bc0e7a5](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/bc0e7a5f0072fba4479d544dd394af34bba2ba04))
* build the GUI image from Interface 20261109 without devtools ([#54](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/54)) ([10dfd09](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/10dfd09ae8458cef42b9f6f7ce5277b14006a4f6))
* strip debug info from the bundled shared libraries ([#53](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/53)) ([ec952ac](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/ec952acfa32440c9ac950030de25b4183c4638ae))


### Bug Fixes

* let repositories other than fvs-build call the reusable workflows ([#52](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/52)) ([5a8a87d](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/5a8a87d0af553de3f25d8efbf30e950e6a77213b))


### Build System

* **deps:** bump checkout, cache, download-artifact and setup-python; group Dependabot updates ([#48](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/48)) ([283f24a](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/283f24a57b316b4df8e3b77c58b0a21698974a7d))
* drop libquadmath0 from the runtime and GUI images ([#58](https://github.com/Vibrant-Planet-Open-Science/fvs-build/issues/58)) ([5ae7311](https://github.com/Vibrant-Planet-Open-Science/fvs-build/commit/5ae7311e02fb867bbdbd3f7a11579ab4bf6aa1ff))
