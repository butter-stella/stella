using System;
using System.Threading.Tasks;
using Natsume.Core.Events;

namespace Natsume.Core.ScenarioEngine
{
    /// <summary>
    /// Utility for awaiting player advance input.
    /// Uses TaskCompletionSource + AdvanceEvent via EventBus.
    /// Thread-safety note: Each call to WaitForAdvanceAsync creates an independent TCS.
    /// The current engine executes commands sequentially (await before next), so overlapping
    /// waits do not occur. If skip/auto mode bypasses the await in the future, callers
    /// should create a new WaitController instance per command rather than reusing one.
    /// </summary>
    public class WaitController
    {
        public Task WaitForAdvanceAsync()
        {
            var tcs = new TaskCompletionSource<bool>();
            Action<AdvanceEvent> handler = null;
            handler = _ =>
            {
                EventBus.EventBus.Unsubscribe(handler);
                tcs.TrySetResult(true);
            };
            EventBus.EventBus.Subscribe(handler);
            return tcs.Task;
        }
    }
}
