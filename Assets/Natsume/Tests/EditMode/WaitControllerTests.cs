using System.Threading.Tasks;
using NUnit.Framework;
using Natsume.Core.EventBus;
using Natsume.Core.Events;
using Natsume.Core.ScenarioEngine;

namespace Natsume.Tests.EditMode
{
    public class WaitControllerTests
    {
        [SetUp]
        public void SetUp()
        {
            EventBus.Clear();
        }

        [Test]
        public async Task WaitForAdvanceAsync_ResolvesOnAdvanceEvent()
        {
            var wait = new WaitController();
            var task = wait.WaitForAdvanceAsync();

            Assert.IsFalse(task.IsCompleted);

            EventBus.Publish(new AdvanceEvent());

            await task;
            Assert.IsTrue(task.IsCompleted);
        }

        [Test]
        public async Task WaitForAdvanceAsync_UnsubscribesAfterResolve()
        {
            var wait = new WaitController();
            var task = wait.WaitForAdvanceAsync();

            EventBus.Publish(new AdvanceEvent());
            await task;

            // Second call should create a new wait, not resolve immediately
            var task2 = wait.WaitForAdvanceAsync();
            Assert.IsFalse(task2.IsCompleted);

            EventBus.Publish(new AdvanceEvent());
            await task2;
            Assert.IsTrue(task2.IsCompleted);
        }

        [Test]
        public async Task WaitForAdvanceAsync_MultipleCallsAreIndependent()
        {
            var wait1 = new WaitController();
            var wait2 = new WaitController();

            var task1 = wait1.WaitForAdvanceAsync();
            var task2 = wait2.WaitForAdvanceAsync();

            // One AdvanceEvent resolves both (both subscribed)
            EventBus.Publish(new AdvanceEvent());

            await task1;
            await task2;
            Assert.IsTrue(task1.IsCompleted);
            Assert.IsTrue(task2.IsCompleted);
        }
    }
}
