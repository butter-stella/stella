using System;
using System.Collections.Generic;
using Natsume.Core.Events;

namespace Natsume.Core.EventBus
{
    /// <summary>
    /// Global event bus for decoupled communication between systems.
    /// Core layer publishes events, Presentation layer subscribes and responds.
    /// </summary>
    public static class EventBus
    {
        private static readonly Dictionary<Type, Delegate> _handlers = new Dictionary<Type, Delegate>();

        public static void Subscribe<T>(Action<T> handler) where T : IEvent
        {
            if (handler == null)
                throw new ArgumentNullException(nameof(handler));

            var type = typeof(T);
            if (_handlers.TryGetValue(type, out var existing))
                _handlers[type] = Delegate.Combine(existing, handler);
            else
                _handlers[type] = handler;
        }

        public static void Unsubscribe<T>(Action<T> handler) where T : IEvent
        {
            if (handler == null)
                throw new ArgumentNullException(nameof(handler));

            var type = typeof(T);
            if (_handlers.TryGetValue(type, out var existing))
            {
                var result = Delegate.Remove(existing, handler);
                if (result == null)
                    _handlers.Remove(type);
                else
                    _handlers[type] = result;
            }
        }

        public static void Publish<T>(T evt) where T : IEvent
        {
            var type = typeof(T);
            if (_handlers.TryGetValue(type, out var existing))
                ((Action<T>)existing).Invoke(evt);
        }

        /// <summary>
        /// Remove all subscribers. Used for test teardown.
        /// </summary>
        public static void Clear()
        {
            _handlers.Clear();
        }
    }
}
