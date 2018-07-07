module served.linters.dscanner;

import std.algorithm;
import std.conv;
import std.file;
import std.path;
import std.string;
import std.json;

import served.types;
import served.linters.diagnosticmanager;
import served.extension;

import workspaced.api;
import workspaced.coms;

static immutable string DScannerDiagnosticSource = "DScanner";

enum DiagnosticSlot = 0;

void lint(Document document)
{
	auto workspaceRoot = workspaceRootFor(document.uri);
	auto ignoredKeys = config(document.uri).dscanner.ignoredKeys;

	auto ini = buildPath(workspaceRoot, "dscanner.ini");
	if (!exists(ini))
		ini = "dscanner.ini";
	auto issues = backend.get!DscannerComponent(workspaceRoot)
		.lint(document.uri.uriToFile, ini, document.text).getYield;
	Diagnostic[] result;

	foreach (issue; issues)
	{
		if (ignoredKeys.canFind(issue.key))
			continue;
		Diagnostic d;
		auto s = issue.description;
		if (s.startsWith("Line is longer than ") && s.endsWith(" characters"))
			d.range = TextRange(Position(cast(uint) issue.line - 1,
					s["Line is longer than ".length .. $ - " characters".length].to!uint),
					Position(cast(uint) issue.line - 1, 1000));
		else
			d.range = TextRange(Position(cast(uint) issue.line - 1, cast(uint) issue.column - 1));
		d.severity = issue.type ? DiagnosticSeverity.warning : DiagnosticSeverity.error;
		d.source = DScannerDiagnosticSource;
		d.message = issue.description;
		d.code = JSONValue(issue.key);
		result ~= d;
	}

	foreach (ref existing; diagnostics[DiagnosticSlot])
		if (existing.uri == document.uri)
		{
			existing.diagnostics = result;
			updateDiagnostics(document.uri);
			return;
		}
	diagnostics[DiagnosticSlot] ~= PublishDiagnosticsParams(document.uri, result);
	updateDiagnostics(document.uri);
}
