CREATE TABLE todos (
  id         STRING(36)  NOT NULL,
  title      STRING(MAX) NOT NULL,
  done       BOOL        NOT NULL DEFAULT (false),
  created_at TIMESTAMP   NOT NULL OPTIONS (allow_commit_timestamp = true),
) PRIMARY KEY (id);
