import Foundation

struct LocalModelArtifact: Equatable, Sendable {
  let relativePath: String
  let byteCount: Int64
  let sha256: String
}

struct LocalModelDefinition: Identifiable, Equatable, Sendable {
  // swiftlint:disable:next identifier_name
  let id: String
  let title: String
  let repository: String
  let revision: String
  let license: String
  let artifacts: [LocalModelArtifact]
  var downloadBytes: Int64 {
    artifacts.reduce(0) { $0 + $1.byteCount }
  }

  var licenseURL: URL? {
    URL(string: "https://huggingface.co/\(repository)/blob/\(revision)/README.md")
  }
}

enum LocalModelCatalog {
  static let primaryID = "parakeet-unified-en-320ms"
  static let correctionID = "parakeet-ctc-110m"
  static let models: [LocalModelDefinition] = [
    LocalModelDefinition(
      id: "parakeet-unified-en-320ms", title: "Parakeet Unified · English",
      repository: "FluidInference/parakeet-unified-en-0.6b-coreml",
      revision: "4252711f6f060f9a2f91e5f081a806d7f45eebd8", license: "CC BY 4.0",
      artifacts: [
        LocalModelArtifact(
          relativePath: "config.json",
          byteCount: 1_355,
          sha256: "6cbe6c76445410c5c6debf3d44c8c3b75e9966bf09bba5cd138c2378c62120f6"
        ),
        LocalModelArtifact(
          relativePath: "metadata.json",
          byteCount: 1_046,
          sha256: "2b26a96b76fe1f7a04d3e867f50c75d6ce5dd1650d0dbcd4c35b591b22305f0e"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_decoder.mlmodelc/analytics/coremldata.bin",
          byteCount: 243,
          sha256: "9ae70f6559989f88b856b326e59315798f9f0d08207a19fcc2dd3287a30088a5"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_decoder.mlmodelc/coremldata.bin",
          byteCount: 560,
          sha256: "ce99c4488840fc463d59f8d4d6d2a9e8ceae8138ead51e3c265dde4d2ba4a0e9"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_decoder.mlmodelc/model.mil",
          byteCount: 13_102,
          sha256: "6e60965b89c93943aa2be2d991c2461108145851fde05e1d048223a32d4cb20d"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_decoder.mlmodelc/weights/weight.bin",
          byteCount: 14_429_952,
          sha256: "96f990461a5986d5e7309ad1a0f36084fbf0f4b28aec35948f8b8d0dcbf8599e"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/analytics/coremldata.bin",
          byteCount: 243,
          sha256: "381de2c3c951682d57c68434c1b514b0a927649959e244207418f1853b0bffa0"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/coremldata.bin",
          byteCount: 513,
          sha256: "53d87fd3585ac4dc6a777f8f3471cd83af7e3f45c02084bbbcba8ec37e92a996"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/model.mil",
          byteCount: 924_694,
          sha256: "9c2e11ffd6e06b6acf1ded06a37701bb2f710bd88842420ad2db4f7385303cc0"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/weights/weight.bin",
          byteCount: 589_486_784,
          sha256: "19335544401c6bd94344b2b3ae633d0478ea5f02b8173c97868c719051ae7397"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_joint_decision_single_step.mlmodelc/analytics/coremldata.bin",
          byteCount: 243,
          sha256: "163877ad14af97ec4107cd854fd1c6d336ee5d40ad25a657cc764fb763f452f5"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin",
          byteCount: 556,
          sha256: "68a081570a48b52ec9379e153bd56748a5408a50be16767601563f231eaeff03"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_joint_decision_single_step.mlmodelc/model.mil",
          byteCount: 9_611,
          sha256: "03c21096090bcd0b71c896c5ae0eb815db31a91c6676f572a7868eee4299abe3"
        ),
        LocalModelArtifact(
          relativePath: "parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin",
          byteCount: 3_446_978,
          sha256: "06831afa6d1beb0c0b10350ebf7886bc37638e951d14e738d7e06fbd2a05012f"
        ),
        LocalModelArtifact(
          relativePath: "vocab.json",
          byteCount: 15_088,
          sha256: "e1a7bff4f5df133c0f4ad47b8e43c96f6bf1865d99126a4c4725ef51d0108bec"
        ),
      ]
    ),
    LocalModelDefinition(
      id: "parakeet-ctc-110m", title: "Dictionary correction",
      repository: "FluidInference/parakeet-ctc-110m-coreml",
      revision: "accdafd8cf8a2ff1cabe3c11e54416b405d409aa", license: "CC BY 4.0",
      artifacts: [
        LocalModelArtifact(
          relativePath: "AudioEncoder.mlmodelc/analytics/coremldata.bin",
          byteCount: 243,
          sha256: "8906c823e9bb3bf6b16d9f0308f98cd70573526333ad85dd767dc3f9ae6b25fa"
        ),
        LocalModelArtifact(
          relativePath: "AudioEncoder.mlmodelc/coremldata.bin",
          byteCount: 505,
          sha256: "a88b002b58193b4c31211754cdfdf220a85f9651dc61caf336ab84400cbc191a"
        ),
        LocalModelArtifact(
          relativePath: "AudioEncoder.mlmodelc/metadata.json",
          byteCount: 3_456,
          sha256: "4f288bfe5cbe867ef1e592cdae33578b2fe59ada69182fc12209879558f985c2"
        ),
        LocalModelArtifact(
          relativePath: "AudioEncoder.mlmodelc/model.mil",
          byteCount: 1_060_924,
          sha256: "2f84ef93a69115e55f3b5d8ce695b3c937de1833d4d229620634fae967cd587e"
        ),
        LocalModelArtifact(
          relativePath: "AudioEncoder.mlmodelc/weights/weight.bin",
          byteCount: 100_778_304,
          sha256: "af0734b4a5d7465ad9e8bb170f0c53c5e6b91ebb75a9bdf88d3f59ae4ad6aebd"
        ),
        LocalModelArtifact(
          relativePath: "MelSpectrogram.mlmodelc/analytics/coremldata.bin",
          byteCount: 243,
          sha256: "22f2a8cba1de25c984050566b534a1d8caf22a82f9fe6c1c6f3149a0dd7e8ae3"
        ),
        LocalModelArtifact(
          relativePath: "MelSpectrogram.mlmodelc/coremldata.bin",
          byteCount: 330,
          sha256: "3a32ec67c76aa0aa2faef518413c311493e89aeb7fa11289fa4b8653ab8a160c"
        ),
        LocalModelArtifact(
          relativePath: "MelSpectrogram.mlmodelc/metadata.json",
          byteCount: 1_962,
          sha256: "5e11d21a65c02bcfc37db43e941978e5d60d59e0efeadfda08e41f33b4f835d3"
        ),
        LocalModelArtifact(
          relativePath: "MelSpectrogram.mlmodelc/model.mil",
          byteCount: 12_584,
          sha256: "0a7cb5693b39667295218bac5c7c09053f6bcd4b32699a83d06ac35d14ac6b79"
        ),
        LocalModelArtifact(
          relativePath: "MelSpectrogram.mlmodelc/weights/weight.bin",
          byteCount: 567_712,
          sha256: "0a89c055bfde9022029d3cc59a23e949385e063974460d8eaec3a7614c3eaaa8"
        ),
        LocalModelArtifact(
          relativePath: "config.json",
          byteCount: 121,
          sha256: "1fd77c83ea89285c242608d95a7992f146867481adc3938be730a064f3a63305"
        ),
        LocalModelArtifact(
          relativePath: "ctc_head_metadata.json",
          byteCount: 382,
          sha256: "26100793bc6d3642d345cc52d7b8611d11510fa870d4d66ad93b204e0ba29d2e"
        ),
        LocalModelArtifact(
          relativePath: "special_tokens_map.json",
          byteCount: 279,
          sha256: "af8c98917af6cb493513e5f1f8a35efdc28fa82cac15b2bb5f065d64f8bc904d"
        ),
        LocalModelArtifact(
          relativePath: "tokenizer.json",
          byteCount: 360_106,
          sha256: "9f7c517c0bf644b1b690ab037bab4d4c53aecd38e047e7154d011013ab9160db"
        ),
        LocalModelArtifact(
          relativePath: "tokenizer_config.json",
          byteCount: 632,
          sha256: "7a29ed0fec88768d8666d65be8dc00ae41a60c4b7758c4df99a912108e62a23a"
        ),
        LocalModelArtifact(
          relativePath: "vocab.json",
          byteCount: 16_086,
          sha256: "319d386eead79aadc80df9c3ecc8340d1a727efb7c02a8847eb940380dd61e1f"
        ),
      ]
    ),
  ]
}
