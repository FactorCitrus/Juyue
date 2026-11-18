import Foundation

/// 旧版本把偏好写在 `legado_*` / `legado.*` 键下。改名牌后先搬到 `juyue_*`，
/// 旧键保留不动，回滚到旧版本仍能读到原来的书架和设置。
public enum JuyueStorageMigration {
    private static let didMigrateKey = "juyue.storageMigrated.v1"

    private static let keyMap: [String: String] = [
        "juyue_app_theme": "legado_app_theme",
        "juyue_bookshelf_v1": "legado_bookshelf_v1",
        "juyue_sources_v1": "legado_sources_v1",
        "juyue_bookmarks_v1": "legado_bookmarks_v1",
        "juyue_book_groups_v1": "legado_book_groups_v1",
        "juyue_text_replace_v1": "legado_text_replace_v1",
        "juyue_system_voice_identifier": "legado_system_voice_identifier",
        "juyue_tts_engine_choice": "legado_tts_engine_choice",
        "juyue_active_tts_source_id": "legado_active_tts_source_id",
        "juyue_tts_hidden_presets": "legado_tts_hidden_presets",
        "juyue_webdav_config_v1": "legado_webdav_config_v1",
        "juyue.scriptDeviceID": "legado.scriptDeviceID",
    ]

    public static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: didMigrateKey) else { return }
        for (newKey, oldKey) in keyMap {
            guard defaults.object(forKey: newKey) == nil,
                  let value = defaults.object(forKey: oldKey) else { continue }
            defaults.set(value, forKey: newKey)
        }
        defaults.set(true, forKey: didMigrateKey)
    }
}
