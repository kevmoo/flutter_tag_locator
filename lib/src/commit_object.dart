extension type CommitObject(Map<String, dynamic> json) {
  CommitObject.extract(Map<String, dynamic> map)
    : json = map['commit'] as Map<String, dynamic>;
  Map<String, dynamic> get _committer =>
      json['committer'] as Map<String, dynamic>;

  DateTime get committerDate => DateTime.parse(_committer['date'] as String);

  String get sha => json['sha'] as String;
}
