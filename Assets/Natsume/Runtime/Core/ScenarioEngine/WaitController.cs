using System;
using System.Threading.Tasks;
using Natsume.Core.Events;

namespace Natsume.Core.ScenarioEngine
{
    /// <summary>
    /// Utility for awaiting player advance input.
    /// Uses TaskCompletionSource + AdvanceEvent via EventBus.
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
