using System;
using System.Collections.Generic;
using System.Linq;
using Natsume.Core.Data;
using Natsume.Core.Interfaces;

namespace Natsume.Core.VariableSystem
{
    /// <summary>
    /// Three-scope variable storage: Global, Scenario, Temp.
    /// Implements ISnapshotProvider to support save/load (Scenario scope only).
    /// </summary>
    public class VariableStore : ISnapshotProvider
    {
        public string ProviderId => "VariableStore";

        private readonly Dictionary<string, object> _global = new Dictionary<string, object>();
        private readonly Dictionary<string, object> _scenario = new Dictionary<string, object>();
        private readonly Dictionary<string, object> _temp = new Dictionary<string, object>();

        private Dictionary<string, object> GetScope(VariableScope scope)
        {
            switch (scope)
            {
                case VariableScope.Global: return _global;
                case VariableScope.Scenario: return _scenario;
                case VariableScope.Temp: return _temp;
                default: throw new ArgumentOutOfRangeException(nameof(scope));
            }
        }

        public void Set(string name, object value, VariableScope scope)
        {
            GetScope(scope)[name] = value;
        }

        public bool Has(string name)
        {
            return _temp.ContainsKey(name) || _scenario.ContainsKey(name) || _global.ContainsKey(name);
        }

        public bool Has(string name, VariableScope scope)
        {
            return GetScope(scope).ContainsKey(name);
        }

        /// <summary>
        /// Get raw value, searching Temp → Scenario → Global.
        /// </summary>
        public object GetRaw(string name)
        {
            if (_temp.TryGetValue(name, out var v)) return v;
            if (_scenario.TryGetValue(name, out v)) return v;
            if (_global.TryGetValue(name, out v)) return v;
            return null;
        }

        /// <summary>
        /// Get raw value from a specific scope.
        /// </summary>
        public object GetRaw(string name, VariableScope scope)
        {
            GetScope(scope).TryGetValue(name, out var v);
            return v;
        }

        public int GetInt(string name, int defaultValue = 0)
        {
            var v = GetRaw(name);
            if (v == null) return defaultValue;
            try { return Convert.ToInt32(v); }
            catch { return defaultValue; }
        }

        public int GetInt(string name, VariableScope scope, int defaultValue = 0)
        {
            var v = GetRaw(name, scope);
            if (v == null) return defaultValue;
            try { return Convert.ToInt32(v); }
            catch { return defaultValue; }
        }

        public float GetFloat(string name, float defaultValue = 0f)
        {
            var v = GetRaw(name);
            if (v == null) return defaultValue;
            try { return Convert.ToSingle(v); }
            catch { return defaultValue; }
        }

        public string GetString(string name, string defaultValue = null)
        {
            var v = GetRaw(name);
            return v?.ToString() ?? defaultValue;
        }

        public bool GetBool(string name, bool defaultValue = false)
        {
            var v = GetRaw(name);
            if (v == null) return defaultValue;
            try { return Convert.ToBoolean(v); }
            catch { return defaultValue; }
        }

        public void ClearScope(VariableScope scope)
        {
            GetScope(scope).Clear();
        }

        // === ISnapshotProvider (Scenario scope) ===

        public object CaptureSnapshot()
        {
            return new Dictionary<string, object>(_scenario);
        }

        public void RestoreSnapshot(object snapshot)
        {
            if (snapshot is Dictionary<string, object> data)
            {
                _scenario.Clear();
                foreach (var kvp in data)
                    _scenario[kvp.Key] = kvp.Value;
            }
        }
    }
}
