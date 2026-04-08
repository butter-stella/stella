## A chapter — narrative grouping unit (issue #97).
## Chapters are author-declared via @chapter in DSL and contain one or more
## scenes. They are the granularity of the flowchart feature: each chapter is
## one node in the scenario graph; cross-chapter transitions are edges.
class_name ChapterData extends RefCounted

var id: String = ""
var display_name: String = ""
var scene_ids: Array = []  # Array[String], in declaration order
