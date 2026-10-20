package rayde.ext;

import ashui.css.Identity;
import ashui.input.Interaction;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.layout.Prop;

/** What the Preview tells whoever is running the extension: an element asked for this event, and here it is. */
typedef PreviewEvent = (node:Int, event:String, payload:Dynamic) -> Void;

/** An element of the extension's view: what the extension said about it, and, while the Preview is shown, its node. */
private class Part {
	public final host:Int;

	/** The element's tag; null for a text node. */
	public final tag:Null<String>;

	public var parent = 0;
	public var children:Array<Int> = [];
	public var text = "";
	public final props:Map<String, Dynamic> = new Map();
	public final order:Array<String> = [];

	/** The events the extension wants from this element. */
	public final listens:Map<String, Bool> = new Map();

	/** The ashui node, null while the Preview is not in a page. */
	public var node:Null<Node>;
	public var control:Null<BridgeControl>;
	public var localState:Dynamic;

	/** The CSS properties the `style` property set, so a new `style` can take away what it no longer has. */
	public var styled:Array<String> = [];

	/** What the text node shows now: the run of text it heads, or its own text. */
	public var shown = "";

	/** The ashui nodes under this element as last placed. */
	public var placed:Array<haxe.Int64> = [];

	/** The events this element has a handler for in ashui; a handler stays and answers only while the event is wanted. */
	public final hooked:Map<String, Bool> = new Map();

	public function new(host:Int, tag:Null<String>) {
		this.host = host;
		this.tag = tag;
	}
}

/**
 * The elements an extension has asked for: the other end of the host's operations. `apply` takes the `ops` of
 * a message and makes them true. What the extension has made is kept as a model, and drawn as ashui nodes
 * only while a page shows it (`show`); `hide` takes the nodes down and the model stays, so the page can be
 * built again around the view, or not be there at all. Classes are styled by the utilities stylesheet and
 * `style` is CSS, so what is drawn is what the cascade says.
 */
class Preview {
	final tree:LayoutTree;
	final parts:Map<Int, Part> = new Map();
	final emit:PreviewEvent;
	final image:Null<(String, String)->{bytes:haxe.io.Bytes, svg:Bool}>;

	/** Whether there are ashui nodes: false until a page shows the view, and again once it is hidden. */
	var shown = false;
	var visibleRoots:Null<Array<Int>>;

	/** The roots, in the order they were mounted, with the name each was mounted under; `node` is null while the view is hidden. */
	public final roots:Array<{id:Int, name:String, node:Null<Node>}> = [];

	/** Counts every change, for whatever shows the tree. */
	public var revision(default, null) = 0;
	public var onProblem:Null<String->Void>;

	public function new(tree:LayoutTree, emit:PreviewEvent, ?image:(String, String)->{bytes:haxe.io.Bytes, svg:Bool}) {
		this.tree = tree;
		this.emit = emit;
		this.image = image;
	}

	/** Takes everything down, the model and the nodes. */
	public function clear():Void {
		for (p in parts) if (p.parent == 0) release(p);
		if (shown)
			for (p in parts)
				if (p.parent == 0 && p.node != null) {
					Identity.forgetSubtree(tree, p.node.id);
					tree.removeSubtree(p.node.id);
				}
		parts.clear();
		roots.resize(0);
		revision++;
	}

	public function count():Int {
		var n = 0;
		for (_ in parts)
			n++;
		return n;
	}

	/** Draws the view as ashui nodes, from what the extension has said. */
	public function show():Void {
		if (shown)
			return;
		shown = true;
		for (p in parts)
			make(p);
		for (p in parts)
			if (p.tag != null) {
				for (name in p.order)
					try style(p, name, p.props.get(name)) catch (e:Dynamic) problem(p, e);
				for (event in p.listens.keys())
					hook(p, event);
			}
		for (p in parts)
			if (p.tag != null)
				refresh(p);
		for (r in roots)
			r.node = parts.get(r.id).node;
		flushControls();
		revision++;
	}

	/** Takes the nodes down, wherever they are: the page that held them may already have taken them with it. The model stays. */
	public function hide():Void {
		if (!shown)
			return;
		for (p in parts) if (p.parent == 0) release(p);
		for (p in parts) {
			if (p.parent == 0 && p.node != null) {
				Identity.forgetSubtree(tree, p.node.id);
				tree.removeSubtree(p.node.id);
			}
		}
		for (p in parts) {
			p.node = null;
			p.hooked.clear();
			p.styled = [];
			p.placed = [];
		}
		for (r in roots)
			r.node = null;
		shown = false;
	}

	/** Applies the operations of an `ops` message in order. */
	public function apply(ops:Array<Dynamic>):Void {
		for (op in ops) {
			var args:Array<Dynamic> = op;
			switch ((args[0] : String)) {
				case "create":
					create(args[1], args[2]);
				case "createText":
					createText(args[1], args[2]);
				case "setText":
					setText(args[1], args[2]);
				case "set":
					set(args[1], args[2], args[3]);
				case "unset":
					set(args[1], args[2], null);
				case "listen":
					listen(args[1], args[2], true);
				case "unlisten":
					listen(args[1], args[2], false);
				case "insert":
					insert(args[1], args[2], args[3]);
				case "remove":
					remove(args[1]);
				case _:
			}
		}
		flushControls();
		revision++;
	}

	function flushControls():Void {
		syncVisibility();
		for (p in parts)
			if (p.control != null)
				try p.control.flush() catch (e:Dynamic) problem(p, e);
		for (p in parts) if (p.control != null && p.control.panels != null) refresh(p);
	}

	/** Hidden Markdown roots keep their document model while releasing decoded images and editor/canvas views. */
	public function setVisibleRoots(ids:Array<Int>):Void {
		visibleRoots = ids;
		syncVisibility();
	}

	function syncVisibility():Void {
		for (part in parts) if (part.control != null) {
			var root = part;
			while (root.parent != 0 && parts.exists(root.parent)) root = parts.get(root.parent);
			part.control.setVisible(visibleRoots == null || visibleRoots.indexOf(root.host) >= 0);
		}
	}

	function problem(p:Part, error:Dynamic):Void {
		if (onProblem != null) onProblem('<${p.tag}>: ' + Std.string(error));
	}

	function release(p:Part):Void {
		for (id in p.children) { var child = parts.get(id); if (child != null) release(child); }
		if (p.control != null) {
			p.localState = p.control.state();
			p.control.dispose();
			p.control = null;
			p.node = null;
		}
	}

	/** The ashui node of a part, made now. */
	function make(p:Part):Void {
		if (p.tag == null) {
			var node = tree.createTextNode(p.text, 14, 1.4);
			Identity.register(tree, node, "text");
			p.node = node;
			p.shown = p.text;
			return;
		}
		var node:Node;
		if (BridgeControl.supported(p.tag)) {
			p.control = new BridgeControl(tree, p.tag, (event, payload) -> {
				if (p.listens.exists(event)) emit(p.host, event, payload);
			}, p.localState, image);
			node = p.control.node;
		} else node = tree.createNode();
		var root = p.tag == "#root";
		var identity = Identity.register(tree, node, root || !Tags.known(p.tag) ? "div" : p.tag);
		if (root)
			identity.setClasses([Utilities.SCOPE, Utilities.SCOPE + "-root"]);
		else
			identity.setAttribute("data-tag", p.tag);
		p.node = node;
	}

	function create(id:Int, tag:String):Void {
		var p = new Part(id, tag);
		parts.set(id, p);
		if (shown)
			make(p);
	}

	function createText(id:Int, text:String):Void {
		var p = new Part(id, null);
		p.text = text;
		parts.set(id, p);
		if (shown)
			make(p);
	}

	function setText(id:Int, text:String):Void {
		var part = parts.get(id);
		if (part == null || part.tag != null)
			return;
		part.text = text;
		var up = parts.get(part.parent);
		if (shown && up != null)
			refresh(up);
	}

	function set(id:Int, name:String, value:Dynamic):Void {
		var part = parts.get(id);
		if (part == null || part.tag == null)
			return;
		if (shown)
			try style(part, name, value) catch (e:Dynamic) { problem(part, e); return; }
		if (value == null) {
			part.props.remove(name);
			part.order.remove(name);
		} else {
			if (!part.props.exists(name))
				part.order.push(name);
			part.props.set(name, value);
		}
	}

	/** Applies one property of an element to its node. */
	function style(part:Part, name:String, value:Dynamic):Void {
		if (part.control != null && part.control.set(name, value)) return;
		var identity = Identity.of(tree, part.node.id);
		if (identity == null)
			return;
		switch name {
			case "virtualizeImages":
				ashui.ui.ImageResidency.configure(part.node, value == true);
			case "class" | "className":
				identity.setClasses(value == null ? (part.tag == "#root" ? classList("", true) : []) : classList(value, part.tag == "#root"));
			case "id":
				identity.setId(value == null ? null : Std.string(value));
			case "style":
				for (n in part.styled)
					identity.setInline(n, null);
				part.styled = [];
				for (d in declarations(value)) {
					identity.setInline(d.name, d.value);
					part.styled.push(d.name);
				}
			case "name" if (part.tag == "#root"):
			case _:
				identity.setAttribute(name, attribute(value));
		}
	}

	/** The classes of a `class` property; a root keeps the Preview's own. */
	static function classList(value:Dynamic, root:Bool):Array<String> {
		var list = [for (c in Std.string(value).split(" ")) if (c != "") c];
		return root ? list.concat([Utilities.SCOPE, Utilities.SCOPE + "-root"]) : list;
	}

	/** An attribute's text: `true` is present with no value, `false` is absent. */
	static function attribute(value:Dynamic):Null<String> {
		if (value == null || value == false)
			return null;
		return value == true ? "" : Std.string(value);
	}

	/** The declarations of a `style` property: CSS text, or an object of camelCase or kebab-case properties. */
	static function declarations(value:Dynamic):Array<{name:String, value:String}> {
		var out = [];
		if (value == null)
			return out;
		if (Std.isOfType(value, String)) {
			for (d in (value : String).split(";")) {
				var at = d.indexOf(":");
				if (at > 0)
					out.push({name: StringTools.trim(d.substr(0, at)), value: StringTools.trim(d.substr(at + 1))});
			}
			return out;
		}
		for (field in Reflect.fields(value))
			out.push({name: kebab(field), value: Std.string(Reflect.field(value, field))});
		return out;
	}

	static function kebab(name:String):String {
		var out = new StringBuf();
		for (i in 0...name.length) {
			var c = name.charAt(i);
			if (c != c.toLowerCase()) {
				out.add("-");
				out.add(c.toLowerCase());
			} else
				out.add(c);
		}
		return out.toString();
	}

	function listen(id:Int, event:String, on:Bool):Void {
		var part = parts.get(id);
		if (part == null)
			return;
		if (!on) {
			part.listens.remove(event);
			return;
		}
		part.listens.set(event, true);
		if (shown)
			hook(part, event);
	}

	/** Gives the node a handler for `event`, once; it answers only while the extension still wants the event. */
	function hook(part:Part, event:String):Void {
		if (part.control != null && part.control.handles(event)) return;
		if (part.hooked.exists(event))
			return;
		part.hooked.set(event, true);
		var id = part.host;
		var interaction = Interaction.of(part.node);
		function wanted(payload:Dynamic):Void
			if (part.listens.exists(event))
				emit(id, event, payload);
		switch event {
			case "click":
				interaction.onClick(e -> wanted({x: e.localX, y: e.localY}));
			case "pointerDown":
				interaction.onPointerDown(e -> wanted({x: e.localX, y: e.localY}));
			case "pointerUp":
				interaction.onPointerUp(e -> wanted({x: e.localX, y: e.localY}));
			case "pointerEnter":
				interaction.onPointerEnter(e -> wanted({}));
			case "pointerLeave":
				interaction.onPointerLeave(e -> wanted({}));
			case _:
		}
	}

	/** Puts `child` last in `parent`, or before `before`; one already in the tree is moved. */
	function insert(parent:Int, child:Int, before:Null<Int>):Void {
		var p = parts.get(parent), c = parts.get(child);
		if (p == null || c == null)
			return;
		var old = c.parent == 0 ? null : parts.get(c.parent);
		if (old != null)
			old.children.remove(child);
		p.children.remove(child);
		var at = before == null ? -1 : p.children.indexOf(before);
		if (at < 0)
			p.children.push(child);
		else
			p.children.insert(at, child);
		c.parent = parent;
		if (shown) {
			if (old != null && old != p)
				refresh(old);
			refresh(p);
		}
	}

	/**
	 * Makes the ashui node's children what the part's are, in order. Text next to text is one run, as in a
	 * browser: the first of them shows all of it and the others are left out, so `Clicked {n} times` is
	 * one line of text and not three boxes that each drop their edge spaces.
	 */
	function refresh(p:Part):Void {
		if (p.control != null && p.control.panels != null) {
			p.control.panels.place([for (id in p.children) {
				var child = parts.get(id);
				{slot:Std.string(child.props.get("slot")), node:child.node};
			}]);
			return;
		}
		if (p.control != null && p.control.content == null) return;
		var ids:Array<haxe.Int64> = [];
		var run:Array<Part> = [];
		function end():Void {
			if (run.length == 0)
				return;
			var text = [for (t in run) t.text].join("");
			if (run[0].shown != text) {
				run[0].shown = text;
				run[0].node.set(Prop.TextContent, text);
			}
			ids.push(run[0].node.id);
			run = [];
		}
		for (c in p.children) {
			var child = parts.get(c);
			if (child.tag == null)
				run.push(child);
			else {
				end();
				ids.push(child.node.id);
			}
		}
		end();
		var same = ids.length == p.placed.length;
		if (same)
			for (i in 0...ids.length)
				if (ids[i] != p.placed[i]) {
					same = false;
					break;
				}
		if (same)
			return;
		p.placed = ids;
		tree.replaceChildren(p.control == null ? p.node.id : p.control.content.id, ids);
	}

	function remove(id:Int):Void {
		var part = parts.get(id);
		if (part == null)
			return;
		var up = parts.get(part.parent);
		if (up != null)
			up.children.remove(id);
		if (shown) {
			if (up != null)
				refresh(up);
			release(part);
			if (part.node != null) {
				Identity.forgetSubtree(tree, part.node.id);
				tree.removeSubtree(part.node.id);
			}
		}
		forget(id);
		for (i in 0...roots.length)
			if (roots[i].id == id) {
				roots.splice(i, 1);
				break;
			}
	}

	function forget(id:Int):Void {
		var part = parts.get(id);
		if (part == null)
			return;
		parts.remove(id);
		for (c in part.children)
			forget(c);
	}

	/** Takes a mounted root down, as the extension's own unmount does. */
	public function removeRoot(id:Int):Void
		remove(id);

	/** Finds the roots the extension has mounted, and records them in `roots`; the one already known is left. */
	public function findRoots():Void {
		for (id => p in parts) {
			if (p.tag != "#root" || Lambda.exists(roots, r -> r.id == id))
				continue;
			roots.push({id: id, name: p.props.exists("name") ? Std.string(p.props.get("name")) : "main", node: p.node});
		}
		roots.sort((a, b) -> a.id - b.id);
	}

	/** The tree as the Elements panel lists it: each element in document order with its depth, tag or text, and properties. */
	public function outline():Array<{id:Int, depth:Int, tag:Null<String>, text:String, props:Array<String>, listens:Array<String>}> {
		var out = [];
		function walk(id:Int, depth:Int):Void {
			var p = parts.get(id);
			if (p == null)
				return;
			out.push({
				id: id,
				depth: depth,
				tag: p.tag,
				text: p.text,
				props: [for (n in p.order) n + "=" + Std.string(p.props.get(n))],
				listens: [for (e in p.listens.keys()) e]
			});
			for (c in p.children)
				walk(c, depth + 1);
		}
		var ids = [for (id => p in parts) if (p.parent == 0) id];
		ids.sort((a, b) -> a - b);
		for (id in ids)
			walk(id, 0);
		return out;
	}
}
