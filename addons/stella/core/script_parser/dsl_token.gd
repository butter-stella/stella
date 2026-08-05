## Token produced by DslLexer from .stla source text.
class_name DslToken extends RefCounted

enum Type {
	SCENE_DIRECTIVE,   # @scene id ["title"]
	CHAPTER_DIRECTIVE, # @chapter id ["display name"]  (issue #97)
	AT_COMMAND,        # @bg, @show, @hide, @expr, @set, @if, @else, @end, @jump, @choice, ...
	DIALOGUE,          # sakura「text」 [#voice:id] [#avatar:id]
	NARRATION,         # 「text」
	MONOLOGUE,         # sakura（text）
	CHOICE_OPTION,     # - "text" -> target [{var op val}] [?if expr]
}

var type: int = Type.AT_COMMAND
var raw_text: String = ""
var line: int = 0
var indent: int = 0
