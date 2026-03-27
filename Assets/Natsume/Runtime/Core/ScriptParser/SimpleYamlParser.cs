using System;
using System.Collections.Generic;
using System.Globalization;

namespace Natsume.Core.ScriptParser
{
    /// <summary>
    /// Lightweight YAML parser for the scenario file schema.
    /// Supports: maps, lists (- item), scalar values (string, int, float, bool).
    /// Does NOT support: anchors, tags, multi-line strings (| or >), flow collections.
    /// Long text values should be written on a single line or wrapped in quotes.
    /// Tab indentation is automatically converted to spaces (2 per tab).
    /// </summary>
    public static class SimpleYamlParser
    {
        public static YamlNode Parse(string yaml)
        {
            if (string.IsNullOrWhiteSpace(yaml))
                return null;

            var lines = new List<string>();
            foreach (var rawLine in yaml.Split('\n'))
            {
                // Normalize: strip CR, replace tabs with 2 spaces (YAML forbids tabs but editors mix them in)
                var line = rawLine.TrimEnd('\r').Replace("\t", "  ");
                // Skip empty lines and comments
                if (string.IsNullOrWhiteSpace(line) || line.TrimStart().StartsWith("#"))
                    continue;
                lines.Add(line);
            }

            if (lines.Count == 0)
                return null;

            int index = 0;
            return ParseNode(lines, ref index, 0);
        }

        private static YamlNode ParseNode(List<string> lines, ref int index, int expectedIndent)
        {
            if (index >= lines.Count)
                return null;

            var line = lines[index];
            var indent = GetIndent(line);
            var trimmed = line.TrimStart();

            // Check if this is a list item
            if (trimmed.StartsWith("- "))
            {
                return ParseList(lines, ref index, indent);
            }

            // Otherwise it's a map
            return ParseMap(lines, ref index, indent);
        }

        private static YamlNode ParseMap(List<string> lines, ref int index, int baseIndent)
        {
            var map = new Dictionary<string, YamlNode>();

            while (index < lines.Count)
            {
                var line = lines[index];
                var indent = GetIndent(line);

                if (indent < baseIndent)
                    break;

                if (indent > baseIndent)
                    break;

                var trimmed = line.TrimStart();

                // List items at map level means we're done with this map
                if (trimmed.StartsWith("- "))
                    break;

                // Split on ": " (colon+space) to avoid cutting values containing colons
                var colonPos = trimmed.IndexOf(": ", StringComparison.Ordinal);
                if (colonPos < 0)
                {
                    // Check for key with no inline value (trailing colon: "key:\n")
                    if (trimmed.EndsWith(":"))
                        colonPos = trimmed.Length - 1;
                    else
                        break;
                }

                var key = trimmed.Substring(0, colonPos).Trim();
                var afterColon = colonPos < trimmed.Length - 1
                    ? trimmed.Substring(colonPos + 2).Trim()
                    : "";

                index++;

                if (!string.IsNullOrEmpty(afterColon))
                {
                    // Inline value: key: value
                    map[key] = new YamlNode(ParseScalar(afterColon));
                }
                else if (index < lines.Count)
                {
                    // Block value: check next line's indent
                    var nextIndent = GetIndent(lines[index]);
                    if (nextIndent > baseIndent)
                    {
                        var nextTrimmed = lines[index].TrimStart();
                        if (nextTrimmed.StartsWith("- "))
                        {
                            map[key] = ParseList(lines, ref index, nextIndent);
                        }
                        else
                        {
                            map[key] = ParseMap(lines, ref index, nextIndent);
                        }
                    }
                    // else: key with no value, skip
                }
            }

            return map.Count > 0 ? new YamlNode(map) : null;
        }

        private static YamlNode ParseList(List<string> lines, ref int index, int baseIndent)
        {
            var list = new List<YamlNode>();

            while (index < lines.Count)
            {
                var line = lines[index];
                var indent = GetIndent(line);

                if (indent < baseIndent)
                    break;

                var trimmed = line.TrimStart();
                if (!trimmed.StartsWith("- "))
                    break;

                var afterDash = trimmed.Substring(2);

                // Check if this is a simple list item: - value
                // or a list item starting a map: - key: value
                // Use ": " to avoid false positives on values containing colons
                if (afterDash.Contains(": ") || afterDash.EndsWith(":"))
                {
                    // Inline map start: - key: value
                    // Reconstruct as a map entry with adjusted indent
                    var itemLines = new List<string>();
                    // Add current line without "- " prefix, at dash content indent
                    var contentIndent = indent + 2;
                    itemLines.Add(new string(' ', contentIndent) + afterDash);
                    index++;

                    // Collect continuation lines that belong to this list item
                    while (index < lines.Count)
                    {
                        var nextLine = lines[index];
                        var nextIndent = GetIndent(nextLine);
                        if (nextIndent <= indent)
                            break;
                        itemLines.Add(nextLine);
                        index++;
                    }

                    int subIndex = 0;
                    var node = ParseMap(itemLines, ref subIndex, contentIndent);
                    list.Add(node ?? new YamlNode(ParseScalar(afterDash)));
                }
                else
                {
                    // Simple scalar: - value
                    list.Add(new YamlNode(ParseScalar(afterDash.Trim())));
                    index++;
                }
            }

            return new YamlNode(list);
        }

        private static object ParseScalar(string value)
        {
            if (value == null)
                return null;

            // Remove surrounding quotes
            if ((value.StartsWith("'") && value.EndsWith("'")) ||
                (value.StartsWith("\"") && value.EndsWith("\"")))
            {
                return value.Substring(1, value.Length - 2);
            }

            // Boolean
            if (value.Equals("true", StringComparison.OrdinalIgnoreCase))
                return true;
            if (value.Equals("false", StringComparison.OrdinalIgnoreCase))
                return false;

            // Null
            if (value.Equals("null", StringComparison.OrdinalIgnoreCase) || value == "~")
                return null;

            // Integer
            if (int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var intVal))
                return intVal;

            // Float
            if (float.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var floatVal))
                return floatVal;

            // Default: string
            return value;
        }

        private static int GetIndent(string line)
        {
            int count = 0;
            foreach (char c in line)
            {
                if (c == ' ') count++;
                else break;
            }
            return count;
        }
    }

    /// <summary>
    /// A simple YAML node that can be a scalar, list, or map.
    /// </summary>
    public class YamlNode
    {
        private readonly object _value;

        public YamlNode(object value)
        {
            _value = value;
        }

        public string GetString(string key)
        {
            if (_value is Dictionary<string, YamlNode> map && map.TryGetValue(key, out var node))
                return node._value?.ToString();
            return null;
        }

        public List<YamlNode> GetList(string key)
        {
            if (_value is Dictionary<string, YamlNode> map && map.TryGetValue(key, out var node))
                return node._value as List<YamlNode>;
            return null;
        }

        public YamlNode GetMap(string key)
        {
            if (_value is Dictionary<string, YamlNode> map && map.TryGetValue(key, out var node))
            {
                if (node._value is Dictionary<string, YamlNode>)
                    return node;
            }
            return null;
        }

        /// <summary>
        /// Convert this map node to a Dictionary&lt;string, object&gt; for CommandData parameters.
        /// Nested maps and lists are converted recursively.
        /// </summary>
        public Dictionary<string, object> ToDictionary()
        {
            var result = new Dictionary<string, object>();
            if (_value is Dictionary<string, YamlNode> map)
            {
                foreach (var kv in map)
                {
                    result[kv.Key] = ConvertToObject(kv.Value);
                }
            }
            return result;
        }

        private static object ConvertToObject(YamlNode node)
        {
            if (node._value is Dictionary<string, YamlNode> map)
            {
                var dict = new Dictionary<string, object>();
                foreach (var kv in map)
                {
                    dict[kv.Key] = ConvertToObject(kv.Value);
                }
                return dict;
            }

            if (node._value is List<YamlNode> list)
            {
                // Check if list contains maps or scalars
                bool allMaps = true;
                foreach (var item in list)
                {
                    if (!(item._value is Dictionary<string, YamlNode>))
                    {
                        allMaps = false;
                        break;
                    }
                }

                if (allMaps)
                {
                    var result = new List<Dictionary<string, object>>();
                    foreach (var item in list)
                        result.Add(item.ToDictionary());
                    return result;
                }
                else
                {
                    var result = new List<object>();
                    foreach (var item in list)
                        result.Add(ConvertToObject(item));
                    return result;
                }
            }

            return node._value;
        }
    }
}
