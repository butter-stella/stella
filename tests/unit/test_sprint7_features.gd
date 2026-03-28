extends GutTest
## Tests for Sprint 7.2: VoiceBookmarkManager, UnlockManager, LocalizationManager.


# --- VoiceBookmarkManager ---

func test_bookmark_add_and_list():
	var bm = VoiceBookmarkManager.new()
	bm.add_bookmark("sakura", "Hello!", "voice_001", "ch1", "s1", 3)
	var bookmarks = bm.get_bookmarks()
	assert_eq(bookmarks.size(), 1)
	assert_eq(bookmarks[0]["character"], "sakura")
	assert_eq(bookmarks[0]["voice_asset"], "voice_001")


func test_bookmark_remove():
	var bm = VoiceBookmarkManager.new()
	bm.add_bookmark("sakura", "Hello!", "voice_001", "ch1", "s1", 3)
	bm.remove_bookmark(0)
	assert_eq(bm.get_bookmarks().size(), 0)


func test_bookmark_filter_by_character():
	var bm = VoiceBookmarkManager.new()
	bm.add_bookmark("sakura", "Hi", "v1", "ch1", "s1", 0)
	bm.add_bookmark("kaito", "Hey", "v2", "ch1", "s1", 1)
	bm.add_bookmark("sakura", "Bye", "v3", "ch1", "s2", 0)

	var filtered = bm.get_bookmarks_by_character("sakura")
	assert_eq(filtered.size(), 2)
	assert_eq(filtered[0]["text"], "Hi")
	assert_eq(filtered[1]["text"], "Bye")


func test_bookmark_snapshot():
	var bm = VoiceBookmarkManager.new()
	bm.add_bookmark("sakura", "Hi", "v1", "ch1", "s1", 0)
	assert_eq(bm.get_provider_id(), "voice_bookmarks")
	var snapshot = bm.capture_snapshot()

	var bm2 = VoiceBookmarkManager.new()
	bm2.restore_snapshot(snapshot)
	assert_eq(bm2.get_bookmarks().size(), 1)


# --- UnlockManager ---

func test_unlock_cg():
	var um = UnlockManager.new()
	assert_false(um.is_unlocked("cg", "sakura_confession"))
	um.unlock("cg", "sakura_confession")
	assert_true(um.is_unlocked("cg", "sakura_confession"))


func test_unlock_bgm():
	var um = UnlockManager.new()
	um.unlock("bgm", "spring_theme")
	assert_true(um.is_unlocked("bgm", "spring_theme"))


func test_get_unlocked_list():
	var um = UnlockManager.new()
	um.unlock("cg", "cg_01")
	um.unlock("cg", "cg_02")
	um.unlock("bgm", "bgm_01")
	assert_eq(um.get_unlocked("cg").size(), 2)
	assert_eq(um.get_unlocked("bgm").size(), 1)


func test_unlock_snapshot():
	var um = UnlockManager.new()
	um.unlock("cg", "cg_01")
	assert_eq(um.get_provider_id(), "unlocks")
	var snapshot = um.capture_snapshot()

	var um2 = UnlockManager.new()
	um2.restore_snapshot(snapshot)
	assert_true(um2.is_unlocked("cg", "cg_01"))


# --- LocalizationManager ---

func test_localization_get_text():
	var lm = LocalizationManager.new()
	lm.load_from_dict("ja", {"greeting": "こんにちは", "farewell": "さようなら"})
	lm.set_locale("ja")
	assert_eq(lm.translate("greeting"), "こんにちは")
	assert_eq(lm.translate("farewell"), "さようなら")


func test_localization_fallback_to_key():
	var lm = LocalizationManager.new()
	lm.set_locale("ja")
	assert_eq(lm.translate("missing_key"), "missing_key")


func test_localization_switch_locale():
	var lm = LocalizationManager.new()
	lm.load_from_dict("ja", {"greeting": "こんにちは"})
	lm.load_from_dict("en", {"greeting": "Hello"})
	lm.set_locale("ja")
	assert_eq(lm.translate("greeting"), "こんにちは")
	lm.set_locale("en")
	assert_eq(lm.translate("greeting"), "Hello")


func test_localization_get_available_locales():
	var lm = LocalizationManager.new()
	lm.load_from_dict("ja", {"a": "1"})
	lm.load_from_dict("en", {"a": "2"})
	var locales = lm.get_available_locales()
	assert_true(locales.has("ja"))
	assert_true(locales.has("en"))
