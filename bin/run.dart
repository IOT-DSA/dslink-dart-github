import "dart:async";
import "dart:convert";

import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";

import "package:github/server.dart";

const String TOKEN_CONFIG = r"$$github_token";
const String USERNAME_CONFIG = r"$$github_username";
const String PASSWORD_CONFIG = r"$$github_password";
const String RATE_LIMIT_REMAINING = "rateLimitRemaining";
const String RATE_LIMIT = "rateLimit";

typedef Action(Map<String, dynamic> params);
typedef ActionWithPath(Path path, Map<String, dynamic> params);
typedef SimpleNode NodeCreator(String path);

LinkProvider link;
SimpleNodeProvider get nodeProvider => link.provider;

verifyNode(SimpleNode node, List<String> requires) {
  for (var x in requires) {
    if (node.get(x) == null) {
      node.remove();
      break;
    }
  }
}

bool doesNodeExist(String path) => nodeProvider.nodes.containsKey(path);

ensureNode(String path, Map<String, dynamic> input) async  {
  SimpleNode node = link[path];
  for (String key in input.keys) {
    if (key.startsWith(r"$")) {
      node.configs[key] = input[key];
    } else if (key.startsWith(r"@")) {
      node.attributes[key] = input[key];
    } else {
      var val = input[key];
      var p = "${key}";
      if (path == "/") {
        p = "/${key}";
      } else {
        p = "${path}/${key}";
      }

      if (val is Function) {
        val = val(p);
      }

      if (val is LocalNode) {
        nodeProvider.setNode(p, val);
      } else {
        nodeProvider.addNode(p, val);
      }
    }
  }
}

addDeleteNode(SimpleNode node) {
  var p = new Path(node.path).child("delete");
  var deleteNode = new DeleteActionNode.forParent(p.path, nodeProvider);
  deleteNode.load({
    r"$name": "Delete",
    r"$invokable": "write"
  });
  nodeProvider.setNode(p.path, deleteNode);
}

addAction(SimpleNode node, String name, handler) {
  var p = new Path(node.path).child(name);
  var n = new SimpleActionNode(p.path, (params) {
    if (handler is Action) {
      return handler(params);
    } else if (handler is ActionWithPath) {
      return handler(p, params);
    } else {
      throw new Exception("Bad Action Handler");
    }
  });

  node.addChild(name, n);
  node.updateList(name);
}

class GitHubNode extends SimpleNode {
  GitHubNode(String path) : super(path);

  void setChildValue(String child, value) {
    link.updateValue("${path}/${child}", value);
  }

  bool childHasSubscriber(String child) {
    return link["${path}/${child}"].hasSubscriber;
  }

  void update(Map map) {
    for (String key in map.keys) {
      var value = map[key];
      if (key.startsWith(r"$")) {
        configs[key] = value;
      } else if (key.startsWith(r"@")) {
        attributes[key] = value;
      } else {
        if (value is LocalNode) {
          addChild(key, value);
        } else if (value is ValueUpdate ||
          value is String ||
          value is num ||
          value is bool) {
          setChildValue(key, value);
        } else if (value is Function) {
          var p = "${path}/${key}";
          var n = value(p);
          print(p);
          nodeProvider.setNode(p, n);
        } else {
          createChild(key, value);
        }
      }
    }
  }
}

Map createPoint(String name, String type, {bool writable: false, String unit}) {
  var m = {
    r"$name": name,
    r"$type": type
  };

  if (writable) {
    m[r"$writable"] = "write";
  }

  if (unit != null) {
    m["@unit"] = unit;
  }

  return m;
}

class AccountNode extends GitHubNode {
  Timer timer;
  GitHub github;

  AccountNode(String path) : super(path);

  @override
  onCreated() async {
    String token = get(TOKEN_CONFIG);
    String username = get(USERNAME_CONFIG);
    String password = get(PASSWORD_CONFIG);
    addDeleteNode(this);

    Authentication auth;

    if (token != null && token.isNotEmpty) {
      auth = new Authentication.withToken(token);
    } else if (username != null && username.isNotEmpty && password != null && password.isNotEmpty) {
      auth = new Authentication.basic(username, password);
    } else {
      auth = new Authentication.anonymous();
    }

    github = createGitHubClient(auth: auth);
    update({
      "pollUserEvents": {
        r"$is": "pollUserEvents",
        r"$name": "Poll User Events",
        r"$invokable": "read",
        r"$params": [
          {
            "name": "user",
            "type": "string"
          },
          {
            "name": "onlyNew",
            "type": "bool",
            "default": true,
            "description": "Only Send New Events"
          }
        ],
        r"$result": "stream",
        r"$columns": [
          {
            "name": "id",
            "type": "string"
          },
          {
            "name": "event",
            "type": "dynamic"
          }
        ]
      },
      "pollPublicEvents": {
        r"$is": "pollPublicEvents",
        r"$name": "Poll Public Events",
        r"$invokable": "read",
        r"$params": [
          {
            "name": "onlyNew",
            "type": "bool",
            "default": true,
            "description": "Only Send New Events"
          }
        ],
        r"$result": "stream",
        r"$columns": [
          {
            "name": "id",
            "type": "string"
          },
          {
            "name": "event",
            "type": "dynamic"
          }
        ]
      },
      "getRepositoryCommits": {
        r"$is": "getRepositoryCommits",
        r"$name": "Get Repository Commits",
        r"$invokable": "read",
        r"$params": [
          {
            "name": "owner",
            "type": "string",
            "placeholder": "IOT-DSA"
          },
          {
            "name": "repository",
            "type": "string",
            "placeholder": "sdk-dslink-dart"
          },
          {
            "name": "count",
            "type": "number"
          }
        ],
        r"$columns": buildActionIO({
          "authorLogin": "string",
          "authorName": "string",
          "committerLogin": "string",
          "committerName": "string",
          "additions": "number",
          "deletions": "number",
          "totalChanges": "number",
          "files": "dynamic",
          "url": "string",
          "sha": "string",
          "message": "string"
        }),
        r"$result": "table"
      },
      "getUserRepositories": {
        r"$is": "getUserRepositories",
        r"$name": "Get User Repositories",
        r"$invokable": "read",
        r"$result": "table",
        r"$params": [
          {
            "name": "user",
            "type": "string"
          }
        ],
        r"$columns": buildActionIO({
          "id": "number",
          "name": "string",
          "fullName": "string",
          "language": "string",
          "size": "number",
          "defaultBranch": "string",
          "description": "string",
          "stars": "number",
          "watchers": "number",
          "hasIssues": "bool",
          "hasWiki": "bool",
          "homepage": "string",
          "url": "string"
        })
      },
      "getContributorStatistics": {
        r"$is": "getContributorStatistics",
        r"$name": "Get Contributor Statistics",
        r"$invokable": "read",
        r"$params": [
          {
            "name": "owner",
            "type": "string",
            "placeholder": "IOT-DSA"
          },
          {
            "name": "repository",
            "type": "string",
            "placeholder": "sdk-dslink-dart"
          }
        ],
        r"$columns": buildActionIO({
          "author": "string",
          "avatarUrl": "string",
          "commits": "number"
        }),
        r"$result": "table"
      },
      RATE_LIMIT_REMAINING: createPoint("Rate Limit Remaining", "int"),
      RATE_LIMIT: createPoint("Rate Limit"," int")
    });

    if (!auth.isAnonymous) {
      update({
        "login": createPoint("Login", "string"),
        "name": createPoint("Name", "string"),
        "email": createPoint("Email", "string"),
        "avatarUrl": createPoint("Avatar Url", "string"),
        "url": createPoint("Url", "string")
      });
    }

    await updateUserInformation();

    timer = Scheduler.every(Interval.ONE_SECOND, () {
      if (childHasSubscriber(RATE_LIMIT_REMAINING)) {
        setChildValue(RATE_LIMIT_REMAINING, github.rateLimitRemaining == null ? 0 : github.rateLimitRemaining);
      }

      if (childHasSubscriber(RATE_LIMIT)) {
        setChildValue(RATE_LIMIT, github.rateLimitLimit == null ? 0 : github.rateLimitLimit);
      }
    });
  }

  updateUserInformation() async {
    CurrentUser user;
    try {
      user = await github.users.getCurrentUser();
    } catch (e) {
      return;
    }

    setChildValue("login", user.login);
    setChildValue("name", user.name);
    setChildValue("email", user.email);
    setChildValue("avatarUrl", user.avatarUrl);
    setChildValue("url", user.htmlUrl);
  }

  getContributorStatistics(Map<String, dynamic> params) async* {
    checkActionParameters(const ["owner", "repository"], params);

    String owner = params["owner"];
    String repository = params["repository"];
    RepositorySlug slug = new RepositorySlug(owner, repository);
    List<ContributorStatistics> stats = await github.repositories.listContributorStats(slug);
    for (ContributorStatistics s in stats) {
      yield [[
        s.author.login,
        s.author.avatarUrl,
        s.total
      ]];
    }
  }

  getUserRepositories(Map<String, dynamic> params) async {
    checkActionParameters(const ["user"], params);

    String user = params["user"];
    return await github.repositories.listUserRepositories(user).map((repo) {
      return [[
        repo.id,
        repo.name,
        repo.fullName,
        repo.language,
        repo.size,
        repo.defaultBranch,
        repo.description,
        repo.stargazersCount,
        repo.watchersCount,
        repo.hasIssues,
        repo.hasWiki,
        repo.homepage,
        repo.htmlUrl
      ]];
    }).toList();
  }

  pollPublicEvents(Map<String, dynamic> params) {
    var poller = github.activity.pollPublicEvents();
    var controller = new StreamController(onCancel: () {
      poller.stop();
    });

    var isOnlyNew = params["onlyNew"];

    if (isOnlyNew is! bool) {
      isOnlyNew = true;
    }

    poller.start(onlyNew: isOnlyNew).listen((Event event) {
      var json = const JsonEncoder().convert(event.json);

      controller.add([event.id, json]);
    });

    return controller.stream;
  }

  getRepositoryCommits(Map<String, dynamic> params) {
    checkActionParameters(const ["owner", "repository"], params);

    String owner = params["owner"];
    String repository = params["repository"];

    if (owner is! String || repository is! String) {
      throw new Exception("Invalid Parameters");
    }

    RepositorySlug slug = new RepositorySlug(owner, repository);

    Stream<List> lists = github.repositories.listCommits(slug).map((RepositoryCommit commit) {
      return [[
        commit.author != null ? commit.author.login : null,
        commit.author != null ? commit.author.name : null,
        commit.committer != null ? commit.committer.login : null,
        commit.committer != null ? commit.committer.name : null,
        commit.stats == null ? 0 : commit.stats.additions,
        commit.stats == null ? 0 : commit.stats.deletions,
        commit.stats == null ? 0 : commit.stats.total,
        commit.files == null ? [] : commit.files.map((file) => {
          "name": file.name,
          "changes": file.changes,
          "status": file.status,
          "blobUrl": file.blobUrl,
          "rawUrl": file.rawUrl
        }).toList(),
        commit.htmlUrl,
        commit.sha,
        commit.commit.message
      ]];
    });

    if (params["count"] is num) {
      return lists.take((params["count"] as num).toInt());
    }

    return lists;
  }

  pollUserEvents(Map<String, dynamic> params) {
    checkActionParameters(["user"], params);
    String user = params["user"];
    var poller = github.activity.pollEventsReceivedByUser(user);
    var controller = new StreamController(onCancel: () {
      poller.stop();
    });

    var isOnlyNew = params["onlyNew"];

    if (isOnlyNew is! bool) {
      isOnlyNew = true;
    }

    poller.start(onlyNew: isOnlyNew).listen((Event event) {
      var json = const JsonEncoder().convert(event.json);

      controller.add([event.id, json]);
    });

    return controller.stream;
  }

  @override
  onRemoving() {
    if (timer != null && timer.isActive) {
      timer.cancel();
    }

    if (github != null) {
      github.dispose();
    }
  }
}

class ActionException {
  final String message;

  ActionException(this.message);

  @override
  String toString() => message;
}

checkActionParameters(List<String> names, Map<String, dynamic> params) {
  for (var name in names) {
    if (params[name] == null) {
      throw new ActionException("Missing Parameter: ${name}");
    }
  }
}

createGitHubAccountWithToken(Map<String, dynamic> params) async {
  checkActionParameters(["name", "token"], params);

  String name = params["name"];
  String token = params["token"];

  String path = "/${name}";

  if (doesNodeExist(path)) {
    throw new ActionException("Account already exists.");
  }

  var github = createGitHubClient(auth: new Authentication.withToken(token));

  try {
    await github.users.getCurrentUser();
  } catch (e) {
    return {
      "success": false,
      "message": "Failed to login to account with token: ${e}"
    };
  }

  await github.dispose();

  var account = new AccountNode(path);
  account.load({
    r"$is": "account",
    TOKEN_CONFIG: token
  });
  nodeProvider.setNode(path, account);

  link.save();

  return {
    "success": true,
    "message": "Account Created."
  };
}

createGitHubAccountWithUsernamePassword(Map<String, dynamic> params) async {
  checkActionParameters(["name", "username", "password"], params);

  String name = params["name"];
  String username = params["username"];
  String password = params["password"];

  String path = "/${name}";

  if (doesNodeExist(path)) {
    throw new ActionException("Account already exists.");
  }

  var github = createGitHubClient(auth: new Authentication.basic(username, password));

  try {
    await github.users.getCurrentUser();
  } catch (e) {
    return {
      "success": false,
      "message": "Failed to login to account: ${e}"
    };
  }

  await github.dispose();

  var account = new AccountNode(path);
  account.load({
    r"$is": "account",
    USERNAME_CONFIG: username,
    PASSWORD_CONFIG: password
  });
  nodeProvider.setNode(path, account);

  link.save();

  return {
    "success": true,
    "message": "Account Created."
  };
}

createGitHubAccountAnonymous(Map<String, dynamic> params) async {
  checkActionParameters(["name"], params);

  String name = params["name"];

  String path = "/${name}";

  if (doesNodeExist(path)) {
    throw new ActionException("Account already exists.");
  }

  var account = new AccountNode(path);
  account.load({
    r"$is": "account"
  });
  nodeProvider.setNode(path, account);

  link.save();

  return {
    "success": true,
    "message": "Account Created."
  };
}

main(List<String> args) async {
  link = new LinkProvider(args, "GitHub-", autoInitialize: false, profiles: {
    "account": (String path) => new AccountNode(path),
    "createGitHubAccountWithToken": (String path) => new SimpleActionNode(path, createGitHubAccountWithToken),
    "createGitHubAccountWithUsernamePassword": (String path) => new SimpleActionNode(path, createGitHubAccountWithUsernamePassword),
    "createGitHubAccountAnonymous": (String path) => new SimpleActionNode(path, createGitHubAccountAnonymous),
    "pollUserEvents": (String path) {
      var p = new Path(path);
      AccountNode node = link[p.parentPath];
      return new SimpleActionNode(path, node == null ? null : node.pollUserEvents);
    },
    "pollPublicEvents": (String path) {
      var p = new Path(path);
      AccountNode node = link[p.parentPath];
      return new SimpleActionNode(path, node == null ? null : node.pollPublicEvents);
    },
    "getUserRepositories": (String path) {
      var p = new Path(path);
      AccountNode node = link[p.parentPath];
      return new SimpleActionNode(path, node == null ? null : node.getUserRepositories);
    },
    "getRepositoryCommits": (String path) {
      var p = new Path(path);
      AccountNode node = link[p.parentPath];
      return new SimpleActionNode(path, node == null ? null : node.getRepositoryCommits);
    },
    "getContributorStatistics": (String path) {
      var p = new Path(path);
      AccountNode node = link[p.parentPath];
      return new SimpleActionNode(path, node == null ? null : node.getContributorStatistics);
    }
  });
  link.init();

  ensureNode("/", {
    "createAccountWithToken": {
      r"$is": "createGitHubAccountWithToken",
      r"$name": "Create Account with Token",
      r"$invokable": "write",
      r"$result": "values",
      r"$params": [
        {
          "name": "name",
          "type": "string"
        },
        {
          "name": "token",
          "type": "string"
        }
      ],
      r"$columns": [
        {
          "name": "success",
          "type": "bool"
        },
        {
          "name": "message",
          "type": "string"
        }
      ]
    },
    "createAccountWithUsernamePassword": {
      r"$is": "createGitHubAccountWithUsernamePassword",
      r"$name": "Create Account with Password",
      r"$invokable": "write",
      r"$result": "values",
      r"$params": [
        {
          "name": "name",
          "type": "string"
        },
        {
          "name": "username",
          "type": "string"
        },
        {
          "name": "password",
          "type": "string"
        }
      ],
      r"$columns": [
        {
          "name": "success",
          "type": "bool"
        },
        {
          "name": "message",
          "type": "string"
        }
      ]
    },
    "createAccountAnonymous": {
      r"$is": "createGitHubAccountAnonymous",
      r"$name": "Create Anonymous Account",
      r"$invokable": "write",
      r"$result": "values",
      r"$params": [
        {
          "name": "name",
          "type": "string"
        }
      ],
      r"$columns": [
        {
          "name": "success",
          "type": "bool"
        },
        {
          "name": "message",
          "type": "string"
        }
      ]
    }
  });

  link.connect();
}

