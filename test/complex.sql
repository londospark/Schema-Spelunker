-- =============================================================================
-- Multi-Tenant Kanban Board — Schema & Sample Data
-- =============================================================================

-- ---------------------------------------------------------------------------
-- TENANCY & USER MODEL
-- ---------------------------------------------------------------------------

CREATE TABLE companies (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,
    slug        TEXT    NOT NULL UNIQUE,
    plan        TEXT    NOT NULL DEFAULT 'free' CHECK(plan IN ('free', 'pro', 'enterprise')),
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE users (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    company_id      INTEGER NOT NULL REFERENCES companies(id),
    email           TEXT    NOT NULL UNIQUE,
    display_name    TEXT    NOT NULL,
    password_hash   TEXT    NOT NULL,
    is_active       INTEGER NOT NULL DEFAULT 1,
    last_login_at   TEXT,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_users_company ON users(company_id);

-- ---------------------------------------------------------------------------
-- TEAMS
-- ---------------------------------------------------------------------------

CREATE TABLE teams (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    company_id  INTEGER NOT NULL REFERENCES companies(id),
    name        TEXT    NOT NULL,
    description TEXT,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_teams_company ON teams(company_id);

CREATE TABLE team_members (
    team_id   INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined_at TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (team_id, user_id)
);

-- ---------------------------------------------------------------------------
-- ROLES & PERMISSIONS
-- ---------------------------------------------------------------------------

CREATE TABLE roles (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    company_id  INTEGER NOT NULL REFERENCES companies(id),
    name        TEXT    NOT NULL,
    is_system   INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    UNIQUE(company_id, name)
);

CREATE TABLE permissions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    resource        TEXT    NOT NULL,
    action          TEXT    NOT NULL,   -- create, read, update, delete, manage
    description     TEXT,
    UNIQUE(resource, action)
);

CREATE TABLE role_permissions (
    role_id       INTEGER NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_id INTEGER NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE role_assignments (
    role_id   INTEGER NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    user_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    team_id   INTEGER REFERENCES teams(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, user_id, team_id)
);

-- ---------------------------------------------------------------------------
-- BOARDS & COLUMNS
-- ---------------------------------------------------------------------------

CREATE TABLE boards (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    company_id  INTEGER NOT NULL REFERENCES companies(id),
    name        TEXT    NOT NULL,
    description TEXT,
    owner_id    INTEGER NOT NULL REFERENCES users(id),
    is_archived INTEGER NOT NULL DEFAULT 0,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_boards_company ON boards(company_id);

CREATE TABLE board_columns (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    board_id    INTEGER NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    name        TEXT    NOT NULL,
    description TEXT,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    colour      TEXT    NOT NULL DEFAULT '#6B7280',
    max_items   INTEGER,                        -- NULL = unlimited
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_columns_board ON board_columns(board_id);

-- ---------------------------------------------------------------------------
-- LABELS
-- ---------------------------------------------------------------------------

CREATE TABLE labels (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    company_id  INTEGER NOT NULL REFERENCES companies(id),
    board_id    INTEGER REFERENCES boards(id) ON DELETE CASCADE,
    name        TEXT    NOT NULL,
    colour      TEXT    NOT NULL DEFAULT '#3B82F6',
    created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_labels_company ON labels(company_id);
CREATE INDEX idx_labels_board  ON labels(board_id);

-- ---------------------------------------------------------------------------
-- CARDS
-- ---------------------------------------------------------------------------

CREATE TABLE cards (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    board_id    INTEGER NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    column_id   INTEGER NOT NULL REFERENCES board_columns(id),
    parent_id   INTEGER REFERENCES cards(id) ON DELETE SET NULL,   -- sub-tasks
    title       TEXT    NOT NULL,
    description TEXT,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    priority    TEXT    NOT NULL DEFAULT 'medium' CHECK(priority IN ('low', 'medium', 'high', 'urgent')),
    size        INTEGER,                        -- story points
    due_at      TEXT,
    is_archived INTEGER NOT NULL DEFAULT 0,
    created_by  INTEGER NOT NULL REFERENCES users(id),
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_cards_board  ON cards(board_id);
CREATE INDEX idx_cards_column ON cards(column_id);
CREATE INDEX idx_cards_parent ON cards(parent_id);

CREATE TABLE card_labels (
    card_id  INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
    label_id INTEGER NOT NULL REFERENCES labels(id) ON DELETE CASCADE,
    PRIMARY KEY (card_id, label_id)
);

CREATE TABLE card_assignees (
    card_id   INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
    user_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    assigned_at TEXT  NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (card_id, user_id)
);

CREATE TABLE card_comments (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    card_id     INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
    user_id     INTEGER NOT NULL REFERENCES users(id),
    body        TEXT    NOT NULL,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_comments_card ON card_comments(card_id);

CREATE TABLE card_activities (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    card_id     INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
    user_id     INTEGER NOT NULL REFERENCES users(id),
    action      TEXT    NOT NULL,         -- created, moved, renamed, assigned, etc.
    detail      TEXT,                     -- JSON payload with before/after
    created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_activities_card ON card_activities(card_id);

-- ---------------------------------------------------------------------------
-- SAMPLE DATA
-- ---------------------------------------------------------------------------

INSERT INTO companies (id, name, slug, plan) VALUES
    (1, 'Acme Corp',  'acme',  'enterprise'),
    (2, 'Startup Inc', 'startup', 'pro'),
    (3, 'Free LTD',    'free',  'free');

INSERT INTO users (id, company_id, email, display_name, password_hash) VALUES
    -- Acme Corp
    (1, 1, 'alice@acme.com',    'Alice',    'hash_alice'),
    (2, 1, 'bob@acme.com',      'Bob',      'hash_bob'),
    (3, 1, 'charlie@acme.com',  'Charlie',  'hash_charlie'),
    (4, 1, 'diana@acme.com',    'Diana',    'hash_diana'),
    -- Startup Inc
    (5, 2, 'eve@startup.io',    'Eve',      'hash_eve'),
    (6, 2, 'frank@startup.io',  'Frank',    'hash_frank'),
    -- Free LTD
    (7, 3, 'grace@free.ltd',    'Grace',    'hash_grace');

INSERT INTO teams (id, company_id, name, description) VALUES
    (1, 1, 'Engineering',     'Builds the product'),
    (2, 1, 'Design',         'Makes it pretty'),
    (3, 1, 'Product',        'Decides what to build'),
    (4, 2, 'Founding Team',  'The OG crew');

INSERT INTO team_members (team_id, user_id) VALUES
    (1, 1), (1, 2),
    (2, 3),
    (3, 1), (3, 4),
    (4, 5), (4, 6);

INSERT INTO roles (id, company_id, name, is_system) VALUES
    (1, 1, 'Admin',    1),
    (2, 1, 'Manager',  1),
    (3, 1, 'Member',   1),
    (4, 1, 'Viewer',   1),
    (5, 2, 'Admin',    1),
    (6, 2, 'Member',   1);

INSERT INTO permissions (id, resource, action, description) VALUES
    (1,  'boards',    'create', 'Create new boards'),
    (2,  'boards',    'read',   'View boards'),
    (3,  'boards',    'update', 'Edit board settings'),
    (4,  'boards',    'delete', 'Delete boards'),
    (5,  'cards',     'create', 'Add cards'),
    (6,  'cards',     'read',   'View cards'),
    (7,  'cards',     'update', 'Edit cards'),
    (8,  'cards',     'delete', 'Delete cards'),
    (9,  'cards',     'assign', 'Assign users to cards'),
    (10, 'columns',   'manage', 'Add / reorder / delete columns'),
    (11, 'labels',    'manage', 'Create and edit labels'),
    (12, 'members',   'invite', 'Invite new members'),
    (13, 'members',   'kick',   'Remove members'),
    (14, 'settings',  'manage', 'Company-wide settings');

INSERT INTO role_permissions (role_id, permission_id) VALUES
    -- Admin gets everything
    (1, 1),  (1, 2),  (1, 3),  (1, 4),  (1, 5),  (1, 6),
    (1, 7),  (1, 8),  (1, 9),  (1, 10), (1, 11), (1, 12),
    (1, 13), (1, 14),
    -- Manager
    (2, 1),  (2, 2),  (2, 3),  (2, 5),  (2, 6),  (2, 7),
    (2, 8),  (2, 9),  (2, 10), (2, 11), (2, 12),
    -- Member
    (3, 2),  (3, 5),  (3, 6),  (3, 7),  (3, 9),
    -- Viewer
    (4, 2),  (4, 6);

INSERT INTO role_assignments (role_id, user_id) VALUES
    (1, 1),   -- Alice is admin
    (2, 4),   -- Diana is manager
    (3, 2),   -- Bob is member
    (3, 3),   -- Charlie is member
    (5, 5),   -- Eve is admin at Startup
    (6, 6);   -- Frank is member at Startup

-- ---------------------------------------------------------------------------
-- BOARDS
-- ---------------------------------------------------------------------------

INSERT INTO boards (id, company_id, name, description, owner_id, sort_order) VALUES
    (1, 1, 'Product Launch',      'Track the Q4 product launch',          1, 1),
    (2, 1, 'Bug Tracker',         'Customer-reported bugs',                2, 2),
    (3, 1, 'Sprint 47',           'Current sprint',                       1, 3),
    (4, 2, 'MVP Roadmap',         'Milestones for v1.0',                   5, 1),
    (5, 3, 'Personal Tasks',      'Just Grace',                            7, 1);

INSERT INTO board_columns (id, board_id, name, sort_order, colour, max_items) VALUES
    -- Product Launch
    (1,  1, 'Backlog',    1, '#6B7280', NULL),
    (2,  1, 'To Do',      2, '#3B82F6', NULL),
    (3,  1, 'In Progress',3, '#F59E0B', 5),
    (4,  1, 'Review',     4, '#8B5CF6', NULL),
    (5,  1, 'Done',       5, '#10B981', NULL),
    -- Bug Tracker
    (6,  2, 'New',        1, '#EF4444', NULL),
    (7,  2, 'Triaged',    2, '#F59E0B', NULL),
    (8,  2, 'Fixed',      3, '#10B981', NULL),
    (9,  2, 'Verified',   4, '#3B82F6', NULL),
    -- Sprint 47
    (10, 3, 'Backlog',    1, '#6B7280', NULL),
    (11, 3, 'Committed',  2, '#3B82F6', NULL),
    (12, 3, 'In Progress',3, '#F59E0B', 3),
    (13, 3, 'Done',       4, '#10B981', NULL),
    -- MVP Roadmap
    (14, 4, 'Ideas',      1, '#6B7280', NULL),
    (15, 4, 'Planned',    2, '#3B82F6', NULL),
    (16, 4, 'Building',   3, '#F59E0B', NULL),
    (17, 4, 'Shipped',    4, '#10B981', NULL),
    -- Personal Tasks
    (18, 5, 'To Do',      1, '#EF4444', 10),
    (19, 5, 'Done',       2, '#10B981', NULL);

-- ---------------------------------------------------------------------------
-- LABELS
-- ---------------------------------------------------------------------------

INSERT INTO labels (id, company_id, board_id, name, colour) VALUES
    (1,  1, 1, 'Frontend',    '#3B82F6'),
    (2,  1, 1, 'Backend',     '#10B981'),
    (3,  1, 1, 'Design',      '#F59E0B'),
    (4,  1, 1, 'Docs',        '#8B5CF6'),
    (5,  1, 1, 'Urgent',      '#EF4444'),
    (6,  1, 2, 'Critical',    '#EF4444'),
    (7,  1, 2, 'Minor',       '#6B7280');

-- ---------------------------------------------------------------------------
-- CARDS
-- ---------------------------------------------------------------------------

INSERT INTO cards (id, board_id, column_id, title, sort_order, priority, size, created_by) VALUES
    -- Product Launch — Backlog
    (1,  1, 1, 'Redesign landing page',       1, 'high',   5, 3),
    (2,  1, 1, 'Write API docs',              2, 'low',    3, 4),
    (3,  1, 1, 'Set up CI/CD pipeline',       3, 'medium', 8, 2),
    -- Product Launch — To Do
    (4,  1, 2, 'Implement user dashboard',     1, 'high',   13, 1),
    (5,  1, 2, 'Add OAuth login',              2, 'urgent', 5, 1),
    -- Product Launch — In Progress
    (6,  1, 3, 'Database migration script',    1, 'high',    5, 2),
    (7,  1, 3, 'Email notification service',   2, 'medium',  8, 2),
    -- Product Launch — Review
    (8,  1, 4, 'Payment integration PR',       1, 'high',    5, 1),
    -- Product Launch — Done
    (9,  1, 5, 'Project scaffolding',          1, 'medium',  2, 1),
    (10, 1, 5, 'Logo design',                  2, 'low',     3, 3),
    -- Bug Tracker
    (11, 2, 6, 'Login page crashes on Safari', 1, 'urgent',  NULL, 3),
    (12, 2, 6, 'Dark mode toggle broken',      2, 'low',     NULL, 4),
    (13, 2, 7, 'Export PDF truncates long text',1, 'high',    NULL, 1),
    (14, 2, 8, 'Fix pagination off-by-one',    1, 'medium',  NULL, 2),
    -- Sprint 47
    (15, 3, 10, 'Refactor auth middleware',    1, 'medium', 5, 1),
    (16, 3, 11, 'Add rate limiting',           1, 'high',   3, 2),
    (17, 3, 12, 'Caching layer for API',       1, 'medium', 8, 1),
    -- MVP Roadmap
    (18, 4, 14, 'User registration',           1, 'high',   8, 5),
    (19, 4, 15, 'Basic kanban board UI',       1, 'high',   13, 5),
    (20, 4, 17, 'Deploy to staging',           1, 'medium', 3, 5),
    -- Personal Tasks
    (21, 5, 18, 'Buy groceries',               1, 'low',    NULL, 7),
    (22, 5, 18, 'Read Odin docs',              2, 'medium', NULL, 7),
    -- Sub-tasks (parent = 6, database migration)
    (23, 1, 3, 'Write up script',              1, 'high',   2, 2),
    (24, 1, 3, 'Test on staging',              2, 'high',   2, 2);

INSERT INTO card_labels (card_id, label_id) VALUES
    (1, 1), (1, 3),
    (2, 4),
    (4, 1), (4, 2),
    (5, 5),
    (6, 2),
    (8, 2),
    (11, 6), (11, 1),
    (12, 7),
    (13, 6);

INSERT INTO card_assignees (card_id, user_id) VALUES
    (1, 3), (1, 4),
    (4, 1), (4, 2),
    (5, 1),
    (6, 2),
    (7, 2),
    (8, 1),
    (11, 3),
    (13, 1),
    (15, 1),
    (16, 2),
    (17, 1),
    (18, 5),
    (19, 5),
    (20, 6);

INSERT INTO card_comments (id, card_id, user_id, body) VALUES
    (1, 1, 4, 'Alice shared a Figma mockup for this in the design channel.'),
    (2, 1, 1, 'Looks great! Lets put it in the next sprint.'),
    (3, 5, 2, 'Do we need Google SSO too?'),
    (4, 5, 1, 'Not for v1 — added to backlog though.'),
    (5, 11, 2, 'Can reproduce in Safari 17.2 on macOS.'),
    (6, 13, 4, 'Seems to only affect PDFs with more than 20 rows.');

INSERT INTO card_activities (id, card_id, user_id, action, detail) VALUES
    (1,  1, 3, 'created',    '{"title": "Redesign landing page"}'),
    (2,  1, 4, 'assigned',   '{"to": [3, 4]}'),
    (3,  1, 4, 'labelled',   '{"labels": ["Frontend", "Design"]}'),
    (4,  5, 1, 'created',    '{"title": "Add OAuth login", "priority": "urgent"}'),
    (5,  5, 1, 'moved',      '{"from": "Backlog", "to": "To Do"}'),
    (6,  6, 2, 'created',    '{"title": "Database migration script"}'),
    (7,  6, 2, 'moved',      '{"from": "To Do", "to": "In Progress"}'),
    (8,  8, 1, 'moved',      '{"from": "In Progress", "to": "Review"}'),
    (9,  9, 1, 'moved',      '{"from": "Review", "to": "Done"}'),
    (10, 11, 3, 'created',   '{"title": "Login page crashes on Safari", "urgency": "urgent"}');

-- ---------------------------------------------------------------------------
-- Vacuum to reclaim space and update stats
-- ---------------------------------------------------------------------------
VACUUM;
