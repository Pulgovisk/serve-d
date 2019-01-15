module served.commands.dcd_update;

import served.git_build;
import served.extension;
import served.types;

import workspaced.api;
import workspaced.coms;

import rm.rf;

import std.algorithm : endsWith;
import std.format : format;
import std.json : JSONValue;
import std.path : chainPath, buildPath, baseName, isAbsolute;

import fs = std.file;
import io = std.stdio;

__gshared bool dcdUpdating;
@protocolNotification("served/updateDCD")
void updateDCD()
{
	scope (exit)
		dcdUpdating = false;

	rpc.notifyMethod("coded/logInstall", "Installing DCD");
	string outputFolder = determineOutputFolder;
	if (fs.exists(outputFolder))
	{
		foreach (file; ["dcd", "DCD", "dcd-client", "dcd-server"])
		{
			auto path = buildPath(outputFolder, file);
			if (fs.exists(path))
			{
				if (fs.isFile(path))
					fs.remove(path);
				else
					rmdirRecurseForce(path);
			}
		}
	}
	if (!fs.exists(outputFolder))
		fs.mkdirRecurse(outputFolder);
	string ext = "";
	version (Windows)
		ext = ".exe";
	string finalDestinationClient;
	string finalDestinationServer;

	bool success;

	enum bundledDCDVersion = "v0.10.2";

	bool compileFromSource = false;
	version (DCDFromSource)
		compileFromSource = true;
	else
	{
		if (!checkVersion(bundledDCDVersion, DCDComponent.latestKnownVersion))
			compileFromSource = true;
	}

	string[] triedPaths;

	if (compileFromSource)
	{
		string[] platformOptions;
		version (Windows)
			platformOptions = ["--arch=x86_mscoff"];
		success = compileDependency(outputFolder, "DCD",
				"https://github.com/Hackerpilot/DCD.git", [[firstConfig.git.path.userPath,
				"submodule", "update", "--init", "--recursive"], ["dub", "build",
				"--config=client"] ~ platformOptions, ["dub", "build",
				"--config=server"] ~ platformOptions]);
		finalDestinationClient = buildPath(outputFolder, "DCD", "dcd-client" ~ ext);
		if (!fs.exists(finalDestinationClient))
			finalDestinationClient = buildPath(outputFolder, "DCD", "bin", "dcd-client" ~ ext);
		finalDestinationServer = buildPath(outputFolder, "DCD", "dcd-server" ~ ext);
		if (!fs.exists(finalDestinationServer))
			finalDestinationServer = buildPath(outputFolder, "DCD", "bin", "dcd-server" ~ ext);

		triedPaths = ["DCD/dcd-client" ~ ext, "DCD/dcd-server" ~ ext,
			"DCD/bin/dcd-client" ~ ext, "DCD/bin/dcd-server" ~ ext];
	}
	else
	{
		string url;

		enum commonPrefix = "https://github.com/dlang-community/DCD/releases/download/"
			~ bundledDCDVersion ~ "/dcd-" ~ bundledDCDVersion;

		version (Win32)
			url = commonPrefix ~ "-windows-x86.zip";
		else version (Win64)
			url = commonPrefix ~ "-windows-x86_64.zip";
		else version (linux)
			url = commonPrefix ~ "-linux-x86_64.tar.gz";
		else version (OSX)
			url = commonPrefix ~ "-osx-x86_64.tar.gz";
		else
			static assert(false);

		import std.stdio : File;
		import std.net.curl : HTTP;
		import std.process : pipeProcess, Redirect, Config, wait;
		import std.zip : ZipArchive;

		try
		{
			rpc.notifyMethod("coded/logInstall", "Downloading from " ~ url ~ " to " ~ outputFolder);
			string destDir = buildPath(outputFolder, url.baseName);
			auto f = File(destDir, "wb");
			auto conn = HTTP(url);
			conn.verifyPeer = false;
			conn.onReceive = (ubyte[] data) { f.rawWrite(data); return data.length; };
			conn.perform();

			rpc.notifyMethod("coded/logInstall", "Extracting download...");
			if (url.endsWith(".tar.gz"))
			{
				rpc.notifyMethod("coded/logInstall", "> tar xvfz " ~ url.baseName);
				auto proc = pipeProcess(["tar", "xvfz", url.baseName],
						Redirect.stdout | Redirect.stderrToStdout, null, Config.none, outputFolder);
				foreach (line; proc.stdout.byLineCopy)
					rpc.notifyMethod("coded/logInstall", line);
				proc.pid.wait;
			}
			else if (url.endsWith(".zip"))
			{
				auto zip = new ZipArchive(fs.read(destDir));
				foreach (name, am; zip.directory)
				{
					if (name.isAbsolute)
						name = "." ~ name;
					zip.expand(am);
					fs.write(chainPath(outputFolder, name), am.expandedData);
				}
			}
			success = true;

			finalDestinationClient = buildPath(outputFolder, "dcd-client" ~ ext);
			finalDestinationServer = buildPath(outputFolder, "dcd-server" ~ ext);

			if (!fs.exists(finalDestinationClient))
				finalDestinationClient = buildPath(outputFolder, "bin", "dcd-client" ~ ext);
			if (!fs.exists(finalDestinationServer))
				finalDestinationServer = buildPath(outputFolder, "bin", "dcd-client" ~ ext);

			triedPaths = ["dcd-client" ~ ext, "dcd-server" ~ ext,
				"bin/dcd-client" ~ ext, "bin/dcd-server" ~ ext];
		}
		catch (Exception e)
		{
			rpc.notifyMethod("coded/logInstall", "Failed installing: " ~ e.toString);
			success = false;
		}
	}

	if (success && (!fs.exists(finalDestinationClient) || !fs.exists(finalDestinationServer)))
	{
		rpc.notifyMethod("coded/logInstall",
				"Successfully downloaded DCD, but could not find the executables.");
		rpc.notifyMethod("coded/logInstall",
				"Please open your user settings and insert the paths for dcd-client and dcd-server manually.");
		rpc.notifyMethod("coded/logInstall", "Download base location: " ~ outputFolder);
		rpc.notifyMethod("coded/logInstall", "");
		rpc.notifyMethod("coded/logInstall", format("Tried %(%s, %)", triedPaths));

		finalDestinationClient = "dcd-client";
		finalDestinationServer = "dcd-server";
	}

	if (success)
	{
		backend.globalConfiguration.set("dcd", "clientPath", finalDestinationClient);
		backend.globalConfiguration.set("dcd", "serverPath", finalDestinationServer);

		foreach (ref workspace; workspaces)
		{
			workspace.config.d.dcdClientPath = finalDestinationClient;
			workspace.config.d.dcdServerPath = finalDestinationServer;
		}
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdClientPath",
				JSONValue(finalDestinationClient), true));
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdServerPath",
				JSONValue(finalDestinationServer), true));
		rpc.notifyMethod("coded/logInstall", "Successfully installed DCD");
		foreach (ref workspace; workspaces)
		{
			auto instance = backend.getInstance(workspace.folder.uri.uriToFile);
			if (instance is null)
				rpc.notifyMethod("coded/logInstall",
						"Failed to find workspace to start DCD for " ~ workspace.folder.uri);
			else
			{
				instance.config.set("dcd", "clientPath", finalDestinationClient);
				instance.config.set("dcd", "serverPath", finalDestinationServer);

				startDCD(instance, workspace.folder.uri);
			}
		}
	}
}
