@:access(NewProjectChecks)
@:access(ProjectWorkbenchChecks)
@:access(ProjectStarterWorkbenchChecks)
class StarterChecks {
	static function main():Void {
		ProjectChecks.run();
		ProjectStarterChecks.run();
		ProjectRunnerChecks.run();
		ExtensionManagerChecks.run();
		NewProjectChecks.main();
		ProjectWorkbenchChecks.main();
		ProjectStarterWorkbenchChecks.main();
		RunnerSettingsChecks.main();
	}
}
