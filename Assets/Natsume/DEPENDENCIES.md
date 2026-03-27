# Third-party Dependencies

Sprint 1 core skeleton does not depend on any third-party packages.
The following are required starting from Sprint 2:

| Package | Version | Source | Usage |
|---------|---------|--------|-------|
| YamlDotNet | >= 15.1.0 | NuGet / manual DLL | YAML scenario parsing |
| UniTask | >= 2.5.0 | OpenUPM `com.cysharp.unitask` | Async/await (replaces Task in interfaces) |
| DOTween | >= 1.2.745 | Asset Store / manual import | Tween animations |

## Notes

- Sprint 1 interfaces use `System.Threading.Tasks.Task` as a placeholder.
  Sprint 2 will migrate to `UniTask` when the package is imported.
- Assembly references for these packages should be added to
  `Natsume.Runtime.asmdef` once imported.
