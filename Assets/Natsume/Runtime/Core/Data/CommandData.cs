using System;
using System.Collections.Generic;

namespace Natsume.Core.Data
{
    /// <summary>
    /// Represents a single command parsed from a scenario script.
    /// Wraps a dictionary of parameters with typed accessors.
    /// </summary>
    public class CommandData
    {
        public string Type { get; }
        public Dictionary<string, object> Parameters { get; }

        public CommandData(string type, Dictionary<string, object> parameters = null)
        {
            Type = type ?? throw new ArgumentNullException(nameof(type));
            Parameters = parameters ?? new Dictionary<string, object>();
        }

        public string GetString(string key, string defaultValue = null)
        {
            if (Parameters.TryGetValue(key, out var value) && value != null)
                return value.ToString();
            return defaultValue;
        }

        public int GetInt(string key, int defaultValue = 0)
        {
            if (Parameters.TryGetValue(key, out var value))
                return Convert.ToInt32(value);
            return defaultValue;
        }

        public float GetFloat(string key, float defaultValue = 0f)
        {
            if (Parameters.TryGetValue(key, out var value))
                return Convert.ToSingle(value);
            return defaultValue;
        }

        public bool GetBool(string key, bool defaultValue = false)
        {
            if (Parameters.TryGetValue(key, out var value))
                return Convert.ToBoolean(value);
            return defaultValue;
        }

        public T Get<T>(string key, T defaultValue = default)
        {
            if (Parameters.TryGetValue(key, out var value) && value is T typed)
                return typed;
            return defaultValue;
        }

        public bool HasKey(string key)
        {
            return Parameters.ContainsKey(key);
        }
    }
}
