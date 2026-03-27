using System.Collections.Generic;
using Natsume.Core.Data;

namespace Natsume.Core.Events
{
    public readonly struct ShowDialogueEvent : IEvent
    {
        public readonly string Character;
        public readonly string Text;
        public readonly string VoiceAssetId;
        public readonly string Mode;

        public ShowDialogueEvent(string character, string text, string voiceAssetId = null, string mode = "adv")
        {
            Character = character;
            Text = text;
            VoiceAssetId = voiceAssetId;
            Mode = mode;
        }
    }

    public readonly struct HideDialogueEvent : IEvent { }

    public readonly struct SceneChangedEvent : IEvent
    {
        public readonly string ScenarioId;
        public readonly string SceneId;

        public SceneChangedEvent(string scenarioId, string sceneId)
        {
            ScenarioId = scenarioId;
            SceneId = sceneId;
        }
    }

    public readonly struct CommandExecutedEvent : IEvent
    {
        public readonly string CommandType;

        public CommandExecutedEvent(string commandType)
        {
            CommandType = commandType;
        }
    }

    public readonly struct ChoiceSelectedEvent : IEvent
    {
        public readonly string SelectedOptionId;

        public ChoiceSelectedEvent(string selectedOptionId)
        {
            SelectedOptionId = selectedOptionId;
        }
    }

    public readonly struct VariableChangedEvent : IEvent
    {
        public readonly string VariableName;
        public readonly object OldValue;
        public readonly object NewValue;
        public readonly VariableScope Scope;

        public VariableChangedEvent(string variableName, object oldValue, object newValue, VariableScope scope)
        {
            VariableName = variableName;
            OldValue = oldValue;
            NewValue = newValue;
            Scope = scope;
        }
    }

    public readonly struct ScenarioStartedEvent : IEvent
    {
        public readonly string ScenarioId;

        public ScenarioStartedEvent(string scenarioId)
        {
            ScenarioId = scenarioId;
        }
    }

    public readonly struct ScenarioEndedEvent : IEvent
    {
        public readonly string ScenarioId;

        public ScenarioEndedEvent(string scenarioId)
        {
            ScenarioId = scenarioId;
        }
    }

    public readonly struct VoiceStartedEvent : IEvent
    {
        public readonly string CharacterName;
        public readonly string VoiceAssetId;

        public VoiceStartedEvent(string characterName, string voiceAssetId)
        {
            CharacterName = characterName;
            VoiceAssetId = voiceAssetId;
        }
    }

    public readonly struct VoiceProgressEvent : IEvent
    {
        public readonly float Progress;
        public readonly float CurrentTime;

        public VoiceProgressEvent(float progress, float currentTime)
        {
            Progress = progress;
            CurrentTime = currentTime;
        }
    }

    public readonly struct VoiceFinishedEvent : IEvent
    {
        public readonly string CharacterName;
        public readonly string VoiceAssetId;

        public VoiceFinishedEvent(string characterName, string voiceAssetId)
        {
            CharacterName = characterName;
            VoiceAssetId = voiceAssetId;
        }
    }

    public readonly struct SettingsChangedEvent : IEvent
    {
        public readonly string SettingName;

        public SettingsChangedEvent(string settingName)
        {
            SettingName = settingName;
        }
    }

    public readonly struct ChangeExpressionEvent : IEvent
    {
        public readonly string CharacterName;
        public readonly string Expression;

        public ChangeExpressionEvent(string characterName, string expression)
        {
            CharacterName = characterName;
            Expression = expression;
        }
    }

    public readonly struct ShowBgEvent : IEvent
    {
        public readonly string Asset;
        public readonly string Transition;
        public readonly float Duration;

        public ShowBgEvent(string asset, string transition = null, float duration = 0f)
        {
            Asset = asset;
            Transition = transition;
            Duration = duration;
        }
    }

    public readonly struct CharShowEvent : IEvent
    {
        public readonly string Character;
        public readonly string Expression;
        public readonly string Position;
        public readonly string Transition;
        public readonly float Duration;

        public CharShowEvent(string character, string expression = null, string position = "center",
            string transition = null, float duration = 0f)
        {
            Character = character;
            Expression = expression;
            Position = position;
            Transition = transition;
            Duration = duration;
        }
    }

    public readonly struct CharHideEvent : IEvent
    {
        public readonly string Character;
        public readonly string Transition;
        public readonly float Duration;

        public CharHideEvent(string character, string transition = null, float duration = 0f)
        {
            Character = character;
            Transition = transition;
            Duration = duration;
        }
    }

    /// <summary>
    /// Published when the player advances dialogue (click, space, etc.).
    /// DialogueCommandHandler awaits this to proceed to the next command.
    /// </summary>
    public readonly struct AdvanceEvent : IEvent { }

    public readonly struct ShowChoiceEvent : IEvent
    {
        public readonly string Prompt;
        public readonly IReadOnlyList<ChoiceOption> Options;

        public ShowChoiceEvent(string prompt, List<ChoiceOption> options)
        {
            Prompt = prompt;
            Options = options?.AsReadOnly();
        }
    }
}
