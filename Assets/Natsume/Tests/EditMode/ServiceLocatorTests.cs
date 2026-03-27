using System;
using NUnit.Framework;
using Natsume.Core.ServiceLocator;

namespace Natsume.Tests.EditMode
{
    public class ServiceLocatorTests
    {
        private interface ITestService { }

        private class TestServiceA : ITestService { }

        private class TestServiceB : ITestService { }

        [SetUp]
        public void SetUp()
        {
            ServiceLocator.Clear();
        }

        [Test]
        public void Register_And_Get_ReturnsSameInstance()
        {
            var instance = new TestServiceA();
            ServiceLocator.Register<ITestService>(instance);

            var result = ServiceLocator.Get<ITestService>();

            Assert.AreSame(instance, result);
        }

        [Test]
        public void Get_Unregistered_ThrowsInvalidOperationException()
        {
            var ex = Assert.Throws<InvalidOperationException>(
                () => ServiceLocator.Get<ITestService>());
            Assert.That(ex.Message, Does.Contain("ITestService"));
            Assert.That(ex.Message, Does.Contain("NatsumeRuntime.Initialize"));
        }

        [Test]
        public void Register_Overwrites_PreviousRegistration()
        {
            var first = new TestServiceA();
            var second = new TestServiceA();
            ServiceLocator.Register<ITestService>(first);
            ServiceLocator.Register<ITestService>(second);

            var result = ServiceLocator.Get<ITestService>();

            Assert.AreSame(second, result);
        }

        [Test]
        public void TryGet_Registered_ReturnsTrueAndInstance()
        {
            var instance = new TestServiceA();
            ServiceLocator.Register<ITestService>(instance);

            bool found = ServiceLocator.TryGet<ITestService>(out var result);

            Assert.IsTrue(found);
            Assert.AreSame(instance, result);
        }

        [Test]
        public void TryGet_Unregistered_ReturnsFalse()
        {
            bool found = ServiceLocator.TryGet<ITestService>(out var result);

            Assert.IsFalse(found);
            Assert.IsNull(result);
        }

        [Test]
        public void IsRegistered_True_WhenRegistered()
        {
            ServiceLocator.Register<ITestService>(new TestServiceA());

            Assert.IsTrue(ServiceLocator.IsRegistered<ITestService>());
        }

        [Test]
        public void IsRegistered_False_WhenNotRegistered()
        {
            Assert.IsFalse(ServiceLocator.IsRegistered<ITestService>());
        }

        [Test]
        public void Unregister_RemovesService()
        {
            ServiceLocator.Register<ITestService>(new TestServiceA());
            ServiceLocator.Unregister<ITestService>();

            Assert.IsFalse(ServiceLocator.IsRegistered<ITestService>());
        }

        [Test]
        public void Register_Null_ThrowsArgumentNullException()
        {
            Assert.Throws<ArgumentNullException>(
                () => ServiceLocator.Register<ITestService>(null));
        }

        [Test]
        public void Clear_RemovesAllServices()
        {
            ServiceLocator.Register<ITestService>(new TestServiceA());
            ServiceLocator.Clear();

            Assert.IsFalse(ServiceLocator.IsRegistered<ITestService>());
        }
    }
}
