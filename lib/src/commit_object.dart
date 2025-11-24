extension type CommitObject(Map<String, dynamic> json) {
  Map<String, dynamic> get _committer =>
      json['committer'] as Map<String, dynamic>;

  DateTime get committerDate => DateTime.parse(_committer['date'] as String);
}
