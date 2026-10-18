package rayde.ext;

/** The element names ashui's user-agent stylesheet knows, which the Preview gives their usual look. */
class Tags {
	static final KNOWN = [
		"div", "span", "p", "h1", "h2", "h3", "h4", "h5", "h6", "strong", "b", "em", "i", "small", "code", "kbd", "mark", "s", "u", "ins", "del", "abbr",
		"button", "a", "ul", "ol", "li", "section", "article", "header", "footer", "nav", "main", "aside", "figure", "figcaption", "blockquote", "pre",
		"hr", "label", "form", "fieldset", "legend", "table", "thead", "tbody", "tr", "td", "th", "dl", "dt", "dd", "details", "summary"
	];

	public static function known(tag:String):Bool
		return KNOWN.indexOf(tag) >= 0;
}
