using NUnit.Framework;
using Natsume.Core.Events;
using Natsume.Core.EventBus;

namespace Natsume.Tests.EditMode
{
    public class EventBusTests
    {
        private struct TestEventA : IEvent
        {
            public int Value;
            public TestEventA(int value) { Value = value; }
        }

        private struct TestEventB : IEvent
        {
            public string Message;
            public TestEventB(string message) { Message = message; }
        }

        [SetUp]
        public void SetUp()
        {
            EventBus.Clear();
        }

        [Test]
        public void Subscribe_And_Publish_ReceivesEvent()
        {
            int received = -1;
            EventBus.Subscribe<TestEventA>(e => received = e.Value);

            EventBus.Publish(new TestEventA(42));

            Assert.AreEqual(42, received);
        }

        [Test]
        public void Publish_WithNoSubscribers_DoesNotThrow()
        {
            Assert.DoesNotThrow(() => EventBus.Publish(new TestEventA(1)));
        }

        [Test]
        public void MultipleSubscribers_AllReceiveEvent()
        {
            int countA = 0;
            int countB = 0;
            EventBus.Subscribe<TestEventA>(_ => countA++);
            EventBus.Subscribe<TestEventA>(_ => countB++);

            EventBus.Publish(new TestEventA(1));

            Assert.AreEqual(1, countA);
            Assert.AreEqual(1, countB);
        }

        [Test]
        public void Unsubscribe_StopsReceivingEvents()
        {
            int count = 0;
            void Handler(TestEventA _) => count++;

            EventBus.Subscribe<TestEventA>(Handler);
            EventBus.Publish(new TestEventA(1));
            Assert.AreEqual(1, count);

            EventBus.Unsubscribe<TestEventA>(Handler);
            EventBus.Publish(new TestEventA(2));
            Assert.AreEqual(1, count);
        }

        [Test]
        public void DifferentEventTypes_AreIsolated()
        {
            bool aCalled = false;
            bool bCalled = false;
            EventBus.Subscribe<TestEventA>(_ => aCalled = true);
            EventBus.Subscribe<TestEventB>(_ => bCalled = true);

            EventBus.Publish(new TestEventB("hello"));

            Assert.IsFalse(aCalled);
            Assert.IsTrue(bCalled);
        }

        [Test]
        public void Unsubscribe_NonExistentHandler_DoesNotThrow()
        {
            void Handler(TestEventA _) { }
            Assert.DoesNotThrow(() => EventBus.Unsubscribe<TestEventA>(Handler));
        }

        [Test]
        public void Clear_RemovesAllSubscribers()
        {
            int count = 0;
            EventBus.Subscribe<TestEventA>(_ => count++);
            EventBus.Subscribe<TestEventB>(_ => count++);

            EventBus.Clear();

            EventBus.Publish(new TestEventA(1));
            EventBus.Publish(new TestEventB("x"));
            Assert.AreEqual(0, count);
        }
    }
}
