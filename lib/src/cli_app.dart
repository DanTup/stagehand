// Copyright (c) 2014, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library stagehand.cli_app;

import 'dart:async';
import 'dart:convert' show JSON;
import 'dart:io' as io;
import 'dart:math';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'package:stagehand/stagehand.dart';
import 'package:stagehand/analytics/analytics_io.dart';
import 'package:stagehand/src/common.dart';

const String APP_NAME = 'stagehand';

// This version must be updated in tandem with the pubspec version.
const String APP_VERSION = '0.1.3-dev';

// The Google Analytics tracking ID for stagehand.
const String _GA_TRACKING_ID = 'UA-55033590-1';

class CliApp {
  final List<Generator> generators;
  final CliLogger logger;

  GeneratorTarget target;
  Analytics analytics;
  io.Directory _cwd;

  CliApp(this.generators, this.logger, [this.target]) {
    assert(generators != null);
    assert(logger != null);

    analytics = new AnalyticsIO(_GA_TRACKING_ID, APP_NAME, APP_VERSION);

    generators.sort();
  }

  io.Directory get cwd => _cwd != null ? _cwd : io.Directory.current;

  /**
   * An override for the directory to generate into; public for testing.
   */
  set cwd(io.Directory value) {
    _cwd = value;
  }

  Future process(List<String> args) {
    ArgParser argParser = _createArgParser();

    ArgResults options;

    try {
      options = argParser.parse(args);
    } catch (e, st) {
      // FormatException: Could not find an option named "foo".
      if (e is FormatException) {
        _out('Error: ${e.message}');
        return new Future.error(new ArgError(e.message));
      } else {
        return new Future.error(e, st);
      }
    }

    if (options.wasParsed('analytics')) {
      analytics.optIn = options['analytics'];
      _out("Analytics ${analytics.optIn ? 'enabled' : 'disabled'}.");
      if (analytics.optIn) analytics.sendScreenView('analytics');
      return new Future.value();
    }

    // This hidden option is used so that our build bots don't emit data.
    if (options['mock-analytics']) {
      analytics = new AnalyticsMock();
    }

    if (options['help'] || args.isEmpty) {
      // Prompt to opt into advanced analytics.
      if (!analytics.hasSetOptIn) {
        _out("Welcome to Stagehand! We collect anonymous usage statistics and crash reports in");
        _out("order to improve the tool (http://goo.gl/6wsncI). Would you like to opt-in to");
        io.stdout.write("additional analytics to help us improve Stagehand [y/yes/no]? ");
        io.stdout.flush();
        String response = io.stdin.readLineSync();
        response = response.toLowerCase().trim();
        analytics.optIn = (response == 'y' || response == 'yes');
        _out('');
      }

      _screenView(options['help'] ? 'help' : 'main');
      _usage(argParser);
      return new Future.value();
    }

    // The `--machine` option emits the list of available generators to stdout
    // as Json. This is useful for tools that don't want to have to parse the
    // output of `--help`. It's an undocumented command line flag, and may go
    // away or change.
    if (options['machine']) {
      _screenView('machine');

      logger.stdout(_createMachineInfo(generators));
      return new Future.value();
    }

    if (options.rest.isEmpty) {
      logger.stderr("No generator specified.\n");
      _usage(argParser);
      return new Future.error(new ArgError('no generator specified'));
    }

    if (options.rest.length >= 2) {
      logger.stderr("Error: too many arguments given.\n");
      _usage(argParser);
      return new Future.error(new ArgError('invalid generator'));
    }

    String generatorName = options.rest.first;
    Generator generator = _getGenerator(generatorName);

    if (generator == null) {
      logger.stderr("'${generatorName}' is not a valid generator.\n");
      _usage(argParser);
      return new Future.error(new ArgError('invalid generator'));
    }

    io.Directory dir = cwd;

    // TOOD(devoncarew): Remove this deprecated option.
    if (options['outdir'] != null) {
      dir = new io.Directory(options['outdir']);
      if (!dir.existsSync()) dir.createSync();
    }

    if (!options['override'] && !_isDirEmpty(dir)) {
      logger.stderr(
'The current directory is not empty. Please create a new project directory, or '
'use --override to force generation into the current directory.');
      return new Future.error(new ArgError('project directory not empty'));
    }

    // Validate and normalize the project name.
    String projectName = path.basename(dir.path);
    if (_validateName(projectName) != null) {
      logger.stderr(_validateName(projectName));
      return new Future.error(new ArgError(_validateName(projectName)));
    }
    projectName = normalizeProjectName(projectName);

    if (target == null) {
      target = new _DirectoryGeneratorTarget(logger, dir);
    }

    _out("Creating ${generatorName} application '${projectName}':");

    _screenView('create');
    analytics.sendEvent('create', generatorName, generator.description);

    String author = options['author'];

    Map vars = {'author': author};

    return generator.generate(projectName, target, additionalVars: vars).then(
        (_) {
      _out("${generator.numFiles()} files written.");
    });
  }

  ArgParser _createArgParser() {
    var argParser = new ArgParser();

    argParser.addFlag('help', abbr: 'h', negatable: false, help: 'Help!');
    argParser.addFlag('analytics', negatable: true,
        help: 'Opt-out of anonymous usage and crash reporting.');
    argParser.addOption('author', defaultsTo: '<your name>',
        help: 'The author name to use for file headers.');

    // This option is deprecated and will go away.
    argParser.addOption('outdir', abbr: 'o', valueHelp: 'path', hide: true);

    // Really, really generate into the current directory.
    argParser.addFlag('override', negatable: false, hide: true);

    // Output the list of available projects as json to stdout.
    argParser.addFlag('machine', negatable: false, hide: true);

    // Mock out analytics - for use on our testing bots.
    argParser.addFlag('mock-analytics', negatable: false, hide: true);

    return argParser;
  }

  String _createMachineInfo(List<Generator> generators) {
    Iterable itor = generators.map((Generator generator) {
      Map m = {
        'name': generator.id,
        'description': generator.description
      };

      if (generator.entrypoint != null) {
        m['entrypoint'] = generator.entrypoint.path;
      }

      return m;
    });
    return JSON.encode(itor.toList());
  }

  String _validateName(String projectName) {
    if (projectName.contains(' ')) {
      return "The project name cannot contain spaces.";
    }

    if (!projectName.startsWith(new RegExp(r'[A-Za-z]'))) {
      return "The project name must start with a letter.";
    }

    // Project name is valid.
    return null;
  }

  void _usage(ArgParser argParser) {
    _out('Stagehand will generate the given application type into the current directory.');
    _out('usage: ${APP_NAME} <generator-name>');
    _out(argParser.getUsage());
    _out('');
    _out('Available generators:');
    int len = generators
      .map((g) => g.id.length)
      .fold(0, (a, b) => max(a, b));
    generators
      .map((g) => "  ${_pad(g.id, len)} - ${g.description}")
      .forEach(logger.stdout);
  }

  Generator _getGenerator(String id) {
    return generators.firstWhere((g) => g.id == id, orElse: () => null);
  }

  void _out(String str) => logger.stdout(str);

  void _screenView(String view) {
    // If the user hasn't opted in, only send a version check - no page data.
    if (!analytics.optIn) view = 'main';
    analytics.sendScreenView(view);
  }

  /**
   * Return true if there are any non-symlinked, non-hidden sub-directories in
   * the given directory.
   */
  bool _isDirEmpty(io.Directory dir) {
    var isHiddenDir = (dir) => path.basename(dir.path).startsWith('.');

    return dir.listSync(followLinks: false)
        .where((entity) => entity is io.Directory)
        .where((entity) => !isHiddenDir(entity))
        .isEmpty;
  }
}

class ArgError implements Exception {
  final String message;
  ArgError(this.message);
  String toString() => message;
}

class CliLogger {
  void stdout(String message) => print(message);
  void stderr(String message) => print(message);
}

class _DirectoryGeneratorTarget extends GeneratorTarget {
  final CliLogger logger;
  final io.Directory dir;

  _DirectoryGeneratorTarget(this.logger, this.dir) {
    dir.createSync();
  }

  Future createFile(String filePath, List<int> contents) {
    io.File file = new io.File(path.join(dir.path, filePath));

    logger.stdout('  ${file.path}');

    return file
      .create(recursive: true)
      .then((_) => file.writeAsBytes(contents));
  }
}

String _pad(String str, int len) {
  while (str.length < len) str += ' ';
  return str;
}