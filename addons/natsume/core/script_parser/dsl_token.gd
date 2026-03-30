## Token produced by DslLexer from .nat source text.
class_name DslToken extends RefCounted

enum Type {
	SCENE_DIRECTIVE,   # @scene id ["title"]
	AT_COMMAND,        # @bg, @show, @hide, @expr, @set, @if, @else, @end, @jump, @choice, ...
	DIALOGUE,          # sakura「text」 [#voice:id]
	NARRATION,         # 「text」
	MONOLOGUE,         # sakura（text）
	CHOICE_OPTION,     # - "text" -> target [{var op val}] [?if expr]
}

var type: int = Type.AT_COMMAND
var raw_text: String = ""
var line: int = 0
var indent: int = 0
