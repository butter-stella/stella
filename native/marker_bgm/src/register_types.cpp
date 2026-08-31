#include "stella_marker_bgm.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_stella_marker_bgm(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<StellaMarkerBgmPlayback>();
	ClassDB::register_class<StellaMarkerBgmStream>();
}

void uninitialize_stella_marker_bgm(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

GDExtensionBool GDE_EXPORT stella_marker_bgm_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_object(
			p_get_proc_address, p_library, r_initialization);
	init_object.register_initializer(initialize_stella_marker_bgm);
	init_object.register_terminator(uninitialize_stella_marker_bgm);
	init_object.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_object.init();
}
}
