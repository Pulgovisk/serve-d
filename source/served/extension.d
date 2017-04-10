module served.extension;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.path;
import std.regex;
import io = std.stdio;
import std.string;

import served.fibermanager;
import served.types;

import workspaced.api;
import workspaced.coms;

bool hasDCD, hasDub, hasDfmt, hasDscanner;

void require(alias val)()
{
	if (!val)
		throw new MethodException(ResponseError(ErrorCode.serverNotInitialized,
				val.stringof[3 .. $] ~ " isn't initialized yet"));
}

bool safe(alias fn, Args...)(Args args)
{
	try
	{
		fn(args);
		return true;
	}
	catch (Exception e)
	{
		io.stderr.writeln(e);
		return false;
	}
}

void changedConfig(string[] paths)
{
	foreach (path; paths)
	{
		switch (path)
		{
		case "d.stdlibPath":
			if (hasDCD)
				dcd.addImports(config.stdlibPath);
			break;
		case "d.projectImportPaths":
			if (hasDCD)
				dcd.addImports(config.d.projectImportPaths);
			break;
		case "d.dubConfiguration":
			if (hasDub)
			{
				auto configs = dub.configurations;
				if (configs.length == 0)
					rpc.window.showInformationMessage(
							"No configurations available for this project. Autocomplete could be broken!");
				else
				{
					auto defaultConfig = config.d.dubConfiguration;
					if (defaultConfig.length)
					{
						if (!configs.canFind(defaultConfig))
							rpc.window.showErrorMessage(
									"Configuration '" ~ defaultConfig
									~ "' which is specified in the config is not available!");
						else
							dub.setConfiguration(defaultConfig);
					}
					else
						dub.setConfiguration(configs[0]);
				}
			}
			break;
		case "d.dubArchType":
			if (hasDub && config.d.dubArchType.length
					&& !dub.setArchType(JSONValue(config.d.dubArchType)))
				rpc.window.showErrorMessage(
						"Arch Type '" ~ config.d.dubArchType
						~ "' which is specified in the config is not available!");
			break;
		case "d.dubBuildType":
			if (hasDub && config.d.dubBuildType.length
					&& !dub.setBuildType(JSONValue(config.d.dubBuildType)))
				rpc.window.showErrorMessage(
						"Build Type '" ~ config.d.dubBuildType
						~ "' which is specified in the config is not available!");
			break;
		case "d.dubCompiler":
			if (hasDub && config.d.dubCompiler.length && !dub.setCompiler(config.d.dubCompiler))
				rpc.window.showErrorMessage(
						"Compiler '" ~ config.d.dubCompiler
						~ "' which is specified in the config is not available!");
			break;
		default:
			break;
		}
	}
}

string[] getPossibleSourceRoots()
{
	import std.file;

	auto confPaths = config.d.projectImportPaths.map!(a => a.isAbsolute ? a
			: buildNormalizedPath(workspaceRoot, a));
	if (!confPaths.empty)
		return confPaths.array;
	auto a = buildNormalizedPath(workspaceRoot, "source");
	auto b = buildNormalizedPath(workspaceRoot, "src");
	if (exists(a))
		return [a];
	if (exists(b))
		return [b];
	return [workspaceRoot];
}

__gshared bool initialStart = true;
InitializeResult initialize(InitializeParams params)
{
	import std.file;

	initialStart = true;
	workspaceRoot = params.rootPath;
	chdir(workspaceRoot);
	hasDub = safe!(dub.startup)(workspaceRoot);
	if (!hasDub)
	{
		io.stderr.writeln("Falling back to fsworkspace");
		fsworkspace.start(workspaceRoot, getPossibleSourceRoots);
	}
	InitializeResult result;
	result.capabilities.textDocumentSync = documents.syncKind;

	result.capabilities.completionProvider = CompletionOptions(false, [".", "("]);
	result.capabilities.signatureHelpProvider = SignatureHelpOptions(["(", ","]);
	result.capabilities.workspaceSymbolProvider = true;
	result.capabilities.definitionProvider = true;
	result.capabilities.hoverProvider = true;
	result.capabilities.codeActionProvider = true;
	
	result.capabilities.documentSymbolProvider = true;
	
	result.capabilities.documentFormattingProvider = true;

	dlangui.start();
	importer.start();

	result.capabilities.codeActionProvider = true;

	changedConfig([__traits(allMembers, Configuration.D)].map!(a => "d." ~ a).array);

	return result;
}

@protocolNotification("workspace/didChangeConfiguration")
void configNotify(DidChangeConfigurationParams params)
{
	if (!initialStart)
		return;
	initialStart = false;

	hasDCD = safe!(dcd.start)(workspaceRoot, config.d.dcdClientPath,
			config.d.dcdServerPath, cast(ushort) 9166, false);
	if (hasDCD)
	{
		try
		{
			syncYield!(dcd.findAndSelectPort)(cast(ushort) 9166);
			dcd.startServer(config.stdlibPath);
			dcd.refreshImports();
		}
		catch (Exception e)
		{
			rpc.window.showErrorMessage("Could not initialize DCD. See log for details!");
			io.stderr.writeln(e);
			hasDCD = false;
			goto DCDEnd;
		}
		io.stderr.writeln("Imports: ", importPathProvider());
	}
	else
		rpc.window.showErrorMessage(format("Could not start DCD. (root=%s, path=%s, %s)", workspaceRoot, config.d.dcdClientPath,
			config.d.dcdServerPath));
DCDEnd:

	hasDscanner = safe!(dscanner.start)(workspaceRoot, config.d.dscannerPath);
	if (!hasDscanner)
		rpc.window.showErrorMessage(format("Could not start DScanner. (root=%s, path=%s)", workspaceRoot, config.d.dscannerPath));

	hasDfmt = safe!(dfmt.start)(workspaceRoot, config.d.dfmtPath);
	if (!hasDfmt)
		rpc.window.showErrorMessage(format("Could not start Dfmt. (root=%s, path=%s)", workspaceRoot, config.d.dfmtPath));
}

@protocolMethod("shutdown")
JSONValue shutdown()
{
	if (hasDub)
		dub.stop();
	if (hasDCD)
		dcd.stop();
	if (hasDfmt)
		dfmt.stop();
	if (hasDscanner)
		dscanner.stop();
	return JSONValue(null);
}

CompletionItemKind convertFromDCDType(string type)
{
	switch (type)
	{
	case "c":
		return CompletionItemKind.class_;
	case "i":
		return CompletionItemKind.interface_;
	case "s":
	case "u":
		return CompletionItemKind.unit;
	case "a":
	case "A":
	case "v":
		return CompletionItemKind.variable;
	case "m":
	case "e":
		return CompletionItemKind.field;
	case "k":
		return CompletionItemKind.keyword;
	case "f":
		return CompletionItemKind.function_;
	case "g":
		return CompletionItemKind.enum_;
	case "P":
	case "M":
		return CompletionItemKind.module_;
	case "l":
		return CompletionItemKind.reference;
	case "t":
	case "T":
		return CompletionItemKind.property;
	default:
		return CompletionItemKind.text;
	}
}

SymbolKind convertFromDCDSearchType(string type)
{
	switch (type)
	{
	case "c":
		return SymbolKind.class_;
	case "i":
		return SymbolKind.interface_;
	case "s":
	case "u":
		return SymbolKind.package_;
	case "a":
	case "A":
	case "v":
		return SymbolKind.variable;
	case "m":
	case "e":
		return SymbolKind.field;
	case "f":
	case "l":
		return SymbolKind.function_;
	case "g":
		return SymbolKind.enum_;
	case "P":
	case "M":
		return SymbolKind.namespace;
	case "t":
	case "T":
		return SymbolKind.property;
	case "k":
	default:
		return cast(SymbolKind) 0;
	}
}

SymbolKind convertFromDscannerType(string type)
{
	switch (type)
	{
	case "g":
		return SymbolKind.enum_;
	case "e":
		return SymbolKind.field;
	case "v":
		return SymbolKind.variable;
	case "i":
		return SymbolKind.interface_;
	case "c":
		return SymbolKind.class_;
	case "s":
		return SymbolKind.class_;
	case "f":
		return SymbolKind.function_;
	case "u":
		return SymbolKind.class_;
	case "T":
		return SymbolKind.property;
	case "a":
		return SymbolKind.field;
	default:
		return cast(SymbolKind) 0;
	}
}

string substr(T)(string s, T start, T end)
{
	if (!s.length)
		return "";
	if (start < 0)
		start = 0;
	if (start >= s.length)
		start = s.length - 1;
	if (end > s.length)
		end = s.length;
	if (end < start)
		return s[start .. start];
	return s[start .. end];
}

string[] extractFunctionParameters(string sig, bool exact = false)
{
	if (!sig.length)
		return [];
	string[] params;
	ptrdiff_t i = sig.length - 1;

	if (sig[i] == ')' && !exact)
		i--;

	ptrdiff_t paramEnd = i + 1;

	void skipStr()
	{
		i--;
		if (sig[i + 1] == '\'')
			for (; i >= 0; i--)
				if (sig[i] == '\'')
					return;
		bool escapeNext = false;
		while (i >= 0)
		{
			if (sig[i] == '\\')
				escapeNext = false;
			if (escapeNext)
				break;
			if (sig[i] == '"')
				escapeNext = true;
			i--;
		}
	}

	void skip(char open, char close)
	{
		i--;
		int depth = 1;
		while (i >= 0 && depth > 0)
		{
			if (sig[i] == '"' || sig[i] == '\'')
				skipStr();
			else
			{
				if (sig[i] == close)
					depth++;
				else if (sig[i] == open)
					depth--;
				i--;
			}
		}
	}

	while (i >= 0)
	{
		switch (sig[i])
		{
		case ',':
			params ~= sig.substr(i + 1, paramEnd).strip;
			paramEnd = i;
			i--;
			break;
		case ';':
		case '(':
			auto param = sig.substr(i + 1, paramEnd).strip;
			if (param.length)
				params ~= param;
			reverse(params);
			return params;
		case ')':
			skip('(', ')');
			break;
		case '}':
			skip('{', '}');
			break;
		case ']':
			skip('[', ']');
			break;
		case '"':
		case '\'':
			skipStr();
			break;
		default:
			i--;
			break;
		}
	}
	reverse(params);
	return params;
}

unittest
{
	void assertEquals(A, B)(A a, B b)
	{
		assert(a == b,
				"\n\"" ~ a.to!string ~ "\"\nis expected to be\n\"" ~ b.to!string ~ "\", but wasn't!");
	}

	assertEquals(extractFunctionParameters("void foo()"), []);
	assertEquals(extractFunctionParameters(`auto bar(int foo, Button, my.Callback cb)`),
			["int foo", "Button", "my.Callback cb"]);
	assertEquals(extractFunctionParameters(`SomeType!(int, "int_") foo(T, Args...)(T a, T b, string[string] map, Other!"(" stuff1, SomeType!(double, ")double") myType, Other!"(" stuff, Other!")")`),
			["T a", "T b", "string[string] map", `Other!"(" stuff1`,
			`SomeType!(double, ")double") myType`, `Other!"(" stuff`, `Other!")"`]);
	assertEquals(extractFunctionParameters(`SomeType!(int,"int_")foo(T,Args...)(T a,T b,string[string] map,Other!"(" stuff1,SomeType!(double,")double")myType,Other!"(" stuff,Other!")")`),
			["T a", "T b", "string[string] map", `Other!"(" stuff1`,
			`SomeType!(double,")double")myType`, `Other!"(" stuff`, `Other!")"`]);
	assertEquals(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4`,
			true), [`4`]);
	assertEquals(extractFunctionParameters(
			`some_garbage(code); before(this); funcCall(4, f(4)`, true), [`4`, `f(4)`]);
	assertEquals(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4, ["a"], JSONValue(["b": JSONValue("c")]), recursive(func, call!s()), "texts )\"(too"`,
			true), [`4`, `["a"]`, `JSONValue(["b": JSONValue("c")])`,
			`recursive(func, call!s())`, `"texts )\"(too"`]);
}

// === Protocol Methods starting here ===

@protocolMethod("textDocument/completion")
CompletionList provideComplete(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return CompletionList.init;
	require!hasDCD;
	auto result = syncYield!(dcd.listCompletion)(document.text,
			cast(int) document.positionToBytes(params.position));
	CompletionItem[] completion;
	switch (result["type"].str)
	{
	case "identifiers":
		foreach (identifier; result["identifiers"].array)
		{
			CompletionItem item;
			item.label = identifier["identifier"].str;
			item.kind = identifier["type"].str.convertFromDCDType;
			completion ~= item;
		}
		goto case;
	case "calltips":
		return CompletionList(false, completion);
	default:
		throw new Exception("Unexpected result from DCD");
	}
}

@protocolMethod("textDocument/signatureHelp")
SignatureHelp provideSignatureHelp(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return SignatureHelp.init;
	require!hasDCD;
	auto pos = cast(int) document.positionToBytes(params.position);
	auto result = syncYield!(dcd.listCompletion)(document.text, pos);
	SignatureInformation[] signatures;
	int[] paramsCounts;
	SignatureHelp help;
	switch (result["type"].str)
	{
	case "calltips":
		foreach (calltip; result["calltips"].array)
		{
			auto sig = SignatureInformation(calltip.str);
			auto funcParams = calltip.str.extractFunctionParameters;

			paramsCounts ~= cast(int) funcParams.length - 1;
			foreach (param; funcParams)
				sig.parameters ~= ParameterInformation(param);

			help.signatures ~= sig;
		}
		auto extractedParams = document.text[0 .. pos].extractFunctionParameters(true);
		help.activeParameter = max(0, cast(int) extractedParams.length - 1);
		size_t[] possibleFunctions;
		foreach (i, count; paramsCounts)
			if (count >= cast(int) extractedParams.length - 1)
				possibleFunctions ~= i;
		help.activeSignature = possibleFunctions.length ? cast(int) possibleFunctions[0] : 0;
		goto case;
	case "identifiers":
		return help;
	default:
		throw new Exception("Unexpected result from DCD");
	}
}

@protocolMethod("workspace/symbol")
SymbolInformation[] provideWorkspaceSymbols(WorkspaceSymbolParams params)
{
	import std.file;

	require!hasDCD;
	auto result = syncYield!(dcd.searchSymbol)(params.query);
	SymbolInformation[] infos;
	TextDocumentManager extraCache;
	foreach (symbol; result.array)
	{
		auto uri = uriFromFile(symbol["file"].str);
		auto doc = documents.tryGet(uri);
		Location location;
		if (!doc.uri)
			doc = extraCache.tryGet(uri);
		if (!doc.uri)
		{
			doc = Document(uri);
			try
			{
				doc.text = readText(symbol["file"].str);
			}
			catch (Exception e)
			{
				io.stderr.writeln(e);
			}
		}
		if (doc.text)
		{
			location = Location(doc.uri,
					TextRange(doc.bytesToPosition(cast(size_t) symbol["position"].integer)));
			infos ~= SymbolInformation(params.query,
					convertFromDCDSearchType(symbol["type"].str), location);
		}
	}
	return infos;
}

@protocolMethod("textDocument/documentSymbol")
SymbolInformation[] provideDocumentSymbols(DocumentSymbolParams params)
{
	require!hasDCD;
	auto result = syncYield!(dscanner.listDefinitions)(uriToFile(params.textDocument.uri));
	if (result.type == JSON_TYPE.NULL)
		return [];
	SymbolInformation[] ret;
	foreach (def; result.array)
	{
		SymbolInformation info;
		info.name = def["name"].str;
		info.location.uri = params.textDocument.uri;
		info.location.range = TextRange(Position(cast(uint) def["line"].integer - 1, 0));
		info.kind = convertFromDscannerType(def["type"].str);
		if (def["type"].str == "f" && def["name"].str == "this")
			info.kind = SymbolKind.constructor;
		const(JSONValue)* ptr;
		auto attribs = def["attributes"];
		if (null !is(ptr = "struct" in attribs) || null !is(ptr = "class" in attribs)
				|| null !is(ptr = "enum" in attribs) || null !is(ptr = "union" in attribs))
			info.containerName = (*ptr).str;
		ret ~= info;
	}
	return ret;
}

@protocolMethod("textDocument/definition")
ArrayOrSingle!Location provideDefinition(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return ArrayOrSingle!Location.init;
	require!hasDCD;
	auto result = syncYield!(dcd.findDeclaration)(document.text,
			cast(int) document.positionToBytes(params.position));
	if (result.type == JSON_TYPE.NULL)
		return ArrayOrSingle!Location.init;
	auto uri = document.uri;
	if (result[0].str != "stdin")
		uri = uriFromFile(result[0].str);
	size_t byteOffset = cast(size_t) result[1].integer;
	Position pos;
	auto found = documents.tryGet(uri);
	if (found.uri)
		pos = found.bytesToPosition(byteOffset);
	else
	{
		string abs = result[0].str;
		if (!abs.isAbsolute)
			abs = buildPath(workspaceRoot, abs);
		pos = Position.init;
		size_t totalLen;
		foreach (line; io.File(abs).byLine(io.KeepTerminator.yes))
		{
			totalLen += line.length;
			if (totalLen >= byteOffset)
				break;
			else
				pos.line++;
		}
	}
	return ArrayOrSingle!Location(Location(uri, TextRange(pos, pos)));
}

@protocolMethod("textDocument/formatting")
TextEdit[] provideFormatting(DocumentFormattingParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	require!hasDfmt;
	string[] args;
	if (config.d.overrideDfmtEditorconfig)
	{
		int maxLineLength = 120;
		int softMaxLineLength = 80;
		if (config.editor.rulers.length == 1)
		{
			maxLineLength = config.editor.rulers[0];
			softMaxLineLength = maxLineLength - 40;
		}
		else if (config.editor.rulers.length >= 2)
		{
			maxLineLength = config.editor.rulers[$ - 1];
			softMaxLineLength = config.editor.rulers[$ - 2];
		}
		//dfmt off
			args = [
				"--align_switch_statements", config.dfmt.alignSwitchStatements.to!string,
				"--brace_style", config.dfmt.braceStyle,
				"--end_of_line", document.eolAt(0).to!string,
				"--indent_size", params.options.tabSize.to!string,
				"--indent_style", params.options.insertSpaces ? "space" : "tab",
				"--max_line_length", maxLineLength.to!string,
				"--soft_max_line_length", softMaxLineLength.to!string,
				"--outdent_attributes", config.dfmt.outdentAttributes.to!string,
				"--space_after_cast", config.dfmt.spaceAfterCast.to!string,
				"--split_operator_at_line_end", config.dfmt.splitOperatorAtLineEnd.to!string,
				"--tab_width", params.options.tabSize.to!string,
				"--selective_import_space", config.dfmt.selectiveImportSpace.to!string,
				"--compact_labeled_statements", config.dfmt.compactLabeledStatements.to!string,
				"--template_constraint_style", config.dfmt.templateConstraintStyle
			];
			//dfmt on
	}
	auto result = syncYield!(dfmt.format)(document.text, args);
	return [TextEdit(TextRange(Position(0, 0),
			document.offsetToPosition(document.text.length)), result.str)];
}

@protocolMethod("textDocument/hover")
Hover provideHover(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return Hover.init;
	require!hasDCD;
	auto docs = syncYield!(dcd.getDocumentation)(document.text,
			cast(int) document.positionToBytes(params.position));
	Hover ret;
	if (docs.type == JSON_TYPE.ARRAY)
		ret.contents = MarkedString(docs.array.map!(a => a.str).join("\n\n"));
	else if (docs.type == JSON_TYPE.STRING)
		ret.contents = MarkedString(docs.str);
	return ret;
}

private auto importRegex = regex(`import ([a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*)*)?`);
private auto undefinedIdentifier = regex(`^undefined identifier '(\w+)'(?:, did you mean .*? '(\w+)'\?)?$`);
private auto undefinedTemplate = regex(`template '(\w+)' is not defined`);
private auto noProperty = regex(`^no property '(\w+)'(?: for type '.*?')?$`);
private auto moduleRegex = regex(`module\s+([a-zA-Z_]\w*\s*(?:\s*\.\s*[a-zA-Z_]\w*)*)\s*;`);
private auto whitespace = regex(`\s*`);

@protocolMethod("textDocument/codeAction")
Command[] provideCodeActions(CodeActionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	Command[] ret;
	foreach (diagnostic; params.context.diagnostics)
	{
		auto match = diagnostic.message.matchFirst(importRegex);
		if (diagnostic.message.canFind("import "))
		{
			if (!match)
				continue;
			return [Command("Import " ~ match[1], "code-d.addImport",
					[JSONValue(match[1]), JSONValue(document.positionToOffset(params.range[0]))])];
		}
		else if (cast(bool)(match = diagnostic.message.matchFirst(undefinedIdentifier))
				|| cast(bool)(match = diagnostic.message.matchFirst(undefinedTemplate))
				|| cast(bool)(match = diagnostic.message.matchFirst(noProperty)))
		{
			string[] files;
			joinAll({
				if (hasDscanner)
					files ~= syncYield!(dscanner.findSymbol)(match[1]).array.map!"a[`file`].str".array;
			}, {
				if (hasDCD)
					files ~= syncYield!(dcd.searchSymbol)(match[1]).array.map!"a[`file`].str".array;
			});
			string[] modules;
			foreach (file; files.sort().uniq)
			{
				if (!isAbsolute(file))
					file = buildNormalizedPath(workspaceRoot, file);
				int lineNo = 0;
				foreach (line; io.File(file).byLine)
				{
					if (++lineNo >= 100)
						break;
					auto match2 = line.matchFirst(moduleRegex);
					if (match2)
					{
						modules ~= match2[1].replaceAll(whitespace, "").idup;
						break;
					}
				}
			}
			foreach (mod; modules.sort().uniq)
				ret ~= Command("Import " ~ mod, "code-d.addImport", [JSONValue(mod),
						JSONValue(document.positionToOffset(params.range[0]))]);
		}
	}
	return ret;
}

@protocolMethod("served/listConfigurations")
string[] listConfigurations()
{
	return dub.configurations;
}

@protocolMethod("served/switchConfig")
bool switchConfig(string value)
{
	return dub.setConfiguration(value);
}

@protocolMethod("served/getConfig")
string getConfig(string value)
{
	return dub.configuration;
}

@protocolMethod("served/listArchTypes")
string[] listArchTypes()
{
	return dub.archTypes;
}

@protocolMethod("served/switchArchType")
bool switchArchType(string value)
{
	return dub.setArchType(JSONValue(["arch-type" : JSONValue(value)]));
}

@protocolMethod("served/getArchType")
string getArchType(string value)
{
	return dub.archType;
}

@protocolMethod("served/listBuildTypes")
string[] listBuildTypes()
{
	return dub.buildTypes;
}

@protocolMethod("served/switchBuildType")
bool switchBuildType(string value)
{
	return dub.setBuildType(JSONValue(["build-type" : JSONValue(value)]));
}

@protocolMethod("served/getBuildType")
string getBuildType()
{
	return dub.buildType;
}

@protocolMethod("served/getCompiler")
string getCompiler()
{
	return dub.compiler;
}

@protocolMethod("served/switchCompiler")
bool switchCompiler(string value)
{
	return dub.setCompiler(value);
}

@protocolMethod("served/addImport")
auto addImport(AddImportParams params)
{
	auto document = documents[params.textDocument.uri];
	return importer.add(params.name.idup, document.text, params.location, params.insertOutermost);
}

@protocolMethod("served/restartServer")
bool restartServer()
{
	syncYield!(dcd.restartServer);
	return true;
}

@protocolMethod("served/updateImports")
bool updateImports()
{
	require!hasDub;
	auto success = syncYield!(dub.update).type == JSON_TYPE.TRUE;
	if (!success)
		return false;
	require!hasDCD;
	dcd.refreshImports();
	return true;
}

// === Protocol Notifications starting here ===

@protocolNotification("textDocument/didSave")
void onDidSaveDocument(DidSaveTextDocumentParams params)
{
	io.stderr.writeln(params);
	auto document = documents[params.textDocument.uri];
	auto fileName = params.textDocument.uri.uriToFile.baseName;

	if (document.languageId == "d" || document.languageId == "diet")
	{
		if (!config.d.enableLinting)
			return;
		joinAll({
			if (hasDscanner)
			{
				if (document.languageId == "diet")
					return;
				import served.linters.dscanner;

				lint(document);
			}
		}, {
			if (hasDub && config.d.enableDubLinting)
			{
				import served.linters.dub;

				lint(document);
			}
		});
	}
	else if (fileName == "dub.json" || fileName == "dub.sdl")
	{
		io.stderr.writeln("Updating dependencies");
		rpc.window.runOrMessage(dub.upgrade(), MessageType.warning, "Could not upgrade dub project");
		rpc.window.runOrMessage(dub.updateImportPaths(true), MessageType.warning,
				"Could not update import paths. Please check your build settings in the status bar.");
	}
}

@protocolNotification("served/killServer")
void killServer()
{
	dcd.killServer();
}