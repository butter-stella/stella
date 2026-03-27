namespace Natsume.Core.Data
{
    /// <summary>
    /// Variable storage scope.
    /// </summary>
    public enum VariableScope
    {
        /// <summary>Cross-save permanent variables (CG unlocks, read flags).</summary>
        Global,

        /// <summary>Current save variables (affection, flags).</summary>
        Scenario,

        /// <summary>Temporary variables, not persisted to save data.</summary>
        Temp
    }
}
