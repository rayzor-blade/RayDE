package rayde.ui;

import ashui.app.ApplicationMenu.MenuGroup;
import ashui.components.Menubar;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;

/** The shared application menu model rendered inside Windows and Linux windows. */
class DesktopMenus extends Component<{groups:Signal<Array<MenuGroup>>}> {
	var previousFocus:Null<ashui.input.Interaction>;

	function render():Element {
		var hook:ashui.layout.LayoutTree->Void = current -> {
			if (current != tree)
				return;
			var focus = ashui.input.Focus.of(tree);
			if (focus == null)
				return;
			for (id in tree.path(focus.node)) {
				var identity = ashui.css.Identity.of(tree, id);
				if (identity != null && (identity.id == "rayde-menubar" || identity.hasClass("ui-menu")))
					return;
			}
			previousFocus = focus;
		};
		ashui.layout.LayoutTree.flushHooks.push(hook);
		ashui.reactive.Owner.onCleanup(() -> {
			ashui.layout.LayoutTree.flushHooks.remove(hook);
			previousFocus = null;
		});
		return <div id="rayde-menubar" class="shrink-0">
			<for {groups in [props.groups.get()]}>${bar(groups)}</for>
		</div>;
	}

	function bar(groups:Array<MenuGroup>):Element
		return new Menubar({}, [for (group in groups) menu(group)]);

	function menu(group:MenuGroup):Element {
		var opened = Signal.make(false);
		return <menubar-menu open={opened} onOpenChange={opened.set}>
			<menubar-trigger>${group.label}</menubar-trigger>
			<menubar-content>
				<for {item in (opened.get() ? group.items : [])}>${row(item)}</for>
			</menubar-content>
		</menubar-menu>;
	}

	function row(item:ashui.app.ApplicationMenu.MenuItem):Element {
		if (item.separator == true)
			return <menubar-separator/>;
		return <menubar-item disabled={item.enabled == false} shortcut={item.shortcut} onSelect={() -> select(item.run)}>${item.label}</menubar-item>;
	}

	function select(run:Null<Void->Void>):Void {
		if (run == null)
			return;
		var target = previousFocus;
		ashui.animation.AnimationScheduler.main.after(0, () -> {
			if (target != null && ashui.input.Interaction.find(target.node) == target)
				ashui.input.Focus.set(target, false);
			run();
		});
	}
}
