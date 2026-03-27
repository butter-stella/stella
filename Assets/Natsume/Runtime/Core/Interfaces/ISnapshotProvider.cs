namespace Natsume.Core.Interfaces
{
    /// <summary>
    /// Provides snapshot capture and restore for a subsystem.
    /// Used by the save system to persist and restore game state.
    /// </summary>
    public interface ISnapshotProvider
    {
        /// <summary>
        /// Unique identifier for this provider (used as key in save data).
        /// </summary>
        string ProviderId { get; }

        /// <summary>
        /// Capture the current state as a serializable snapshot.
        /// </summary>
        object CaptureSnapshot();

        /// <summary>
        /// Restore state from a previously captured snapshot.
        /// </summary>
        void RestoreSnapshot(object snapshot);
    }
}
