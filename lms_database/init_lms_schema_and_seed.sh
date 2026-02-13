#!/bin/bash
set -euo pipefail

# LMS database schema + seed initializer
# - Uses db_connection.txt as the source of truth for connection details.
# - Safe to run multiple times (uses IF NOT EXISTS / ON CONFLICT where appropriate).
# - Keeps existing operational scripts intact (startup/backup/restore).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${SCRIPT_DIR}/db_connection.txt"

if [ ! -f "${CONN_FILE}" ]; then
  echo "❌ db_connection.txt not found at: ${CONN_FILE}"
  echo "Run ./startup.sh first to provision Postgres and write db_connection.txt"
  exit 1
fi

PSQL_BASE_CMD="$(cat "${CONN_FILE}" | tr -d '\n\r' | xargs)"
if [[ "${PSQL_BASE_CMD}" != psql\ postgresql://* ]]; then
  echo "❌ Unexpected db_connection.txt format. Expected: 'psql postgresql://...'"
  echo "Got: ${PSQL_BASE_CMD}"
  exit 1
fi

# Always stop on SQL error, and keep output concise
PSQL="${PSQL_BASE_CMD} -v ON_ERROR_STOP=1 -q"

echo "Initializing LMS schema using: ${CONN_FILE}"

run_sql () {
  local sql="$1"
  # Use -c per the container rules (one statement per call).
  ${PSQL} -c "${sql}"
}

# ---------- Extensions ----------
run_sql "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
run_sql "CREATE EXTENSION IF NOT EXISTS citext;"

# ---------- Enum types (for consistent domains) ----------
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_status') THEN CREATE TYPE user_status AS ENUM ('ACTIVE','SUSPENDED','DELETED'); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'course_status') THEN CREATE TYPE course_status AS ENUM ('DRAFT','PUBLISHED','ARCHIVED'); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'enrollment_status') THEN CREATE TYPE enrollment_status AS ENUM ('ACTIVE','COMPLETED','DROPPED'); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'content_type') THEN CREATE TYPE content_type AS ENUM ('TEXT','VIDEO','FILE','QUIZ','LINK'); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'submission_status') THEN CREATE TYPE submission_status AS ENUM ('DRAFT','SUBMITTED','GRADED','RETURNED'); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_channel') THEN CREATE TYPE notification_channel AS ENUM ('IN_APP','EMAIL'); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'discussion_type') THEN CREATE TYPE discussion_type AS ENUM ('GENERAL','QNA'); END IF; END \$\$;"

# ---------- Core: roles/users/auth ----------
run_sql "CREATE TABLE IF NOT EXISTS roles (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL UNIQUE, description text, created_at timestamptz NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email citext NOT NULL UNIQUE, password_hash text NOT NULL, first_name text NOT NULL, last_name text NOT NULL, status user_status NOT NULL DEFAULT 'ACTIVE', created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), last_login_at timestamptz);"

run_sql "CREATE TABLE IF NOT EXISTS user_roles (user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, role_id uuid NOT NULL REFERENCES roles(id) ON DELETE RESTRICT, assigned_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (user_id, role_id));"
run_sql "CREATE INDEX IF NOT EXISTS idx_user_roles_role_id ON user_roles(role_id);"

run_sql "CREATE TABLE IF NOT EXISTS refresh_tokens (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, token_hash text NOT NULL UNIQUE, issued_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL, revoked_at timestamptz, user_agent text, ip_address text);"
run_sql "CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_refresh_tokens_expires_at ON refresh_tokens(expires_at);"

# ---------- Courses / modules / content ----------
run_sql "CREATE TABLE IF NOT EXISTS courses (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text UNIQUE, title text NOT NULL, description text, status course_status NOT NULL DEFAULT 'DRAFT', start_date date, end_date date, created_by uuid REFERENCES users(id) ON DELETE SET NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"
run_sql "CREATE INDEX IF NOT EXISTS idx_courses_status ON courses(status);"
run_sql "CREATE INDEX IF NOT EXISTS idx_courses_created_by ON courses(created_by);"

run_sql "CREATE TABLE IF NOT EXISTS course_instructors (course_id uuid NOT NULL REFERENCES courses(id) ON DELETE CASCADE, instructor_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, assigned_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(course_id, instructor_id));"
run_sql "CREATE INDEX IF NOT EXISTS idx_course_instructors_instructor_id ON course_instructors(instructor_id);"

run_sql "CREATE TABLE IF NOT EXISTS modules (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), course_id uuid NOT NULL REFERENCES courses(id) ON DELETE CASCADE, title text NOT NULL, description text, sort_order int NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(course_id, sort_order));"
run_sql "CREATE INDEX IF NOT EXISTS idx_modules_course_id ON modules(course_id);"

run_sql "CREATE TABLE IF NOT EXISTS content_items (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), module_id uuid NOT NULL REFERENCES modules(id) ON DELETE CASCADE, title text NOT NULL, type content_type NOT NULL, body text, url text, file_path text, sort_order int NOT NULL DEFAULT 0, published_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(module_id, sort_order));"
run_sql "CREATE INDEX IF NOT EXISTS idx_content_items_module_id ON content_items(module_id);"

# ---------- Enrollments ----------
run_sql "CREATE TABLE IF NOT EXISTS enrollments (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), course_id uuid NOT NULL REFERENCES courses(id) ON DELETE CASCADE, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, status enrollment_status NOT NULL DEFAULT 'ACTIVE', enrolled_at timestamptz NOT NULL DEFAULT now(), completed_at timestamptz, UNIQUE(course_id, user_id));"
run_sql "CREATE INDEX IF NOT EXISTS idx_enrollments_user_id ON enrollments(user_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_enrollments_course_id ON enrollments(course_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_enrollments_status ON enrollments(status);"

# ---------- Assignments / submissions / grades ----------
run_sql "CREATE TABLE IF NOT EXISTS assignments (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), course_id uuid NOT NULL REFERENCES courses(id) ON DELETE CASCADE, module_id uuid REFERENCES modules(id) ON DELETE SET NULL, title text NOT NULL, description text, due_at timestamptz, max_points numeric(10,2) NOT NULL DEFAULT 100.00, created_by uuid REFERENCES users(id) ON DELETE SET NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"
run_sql "CREATE INDEX IF NOT EXISTS idx_assignments_course_id ON assignments(course_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_assignments_due_at ON assignments(due_at);"

run_sql "CREATE TABLE IF NOT EXISTS submissions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), assignment_id uuid NOT NULL REFERENCES assignments(id) ON DELETE CASCADE, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, status submission_status NOT NULL DEFAULT 'SUBMITTED', submitted_at timestamptz NOT NULL DEFAULT now(), content text, file_path text, UNIQUE(assignment_id, user_id));"
run_sql "CREATE INDEX IF NOT EXISTS idx_submissions_assignment_id ON submissions(assignment_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_submissions_user_id ON submissions(user_id);"

run_sql "CREATE TABLE IF NOT EXISTS grades (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), submission_id uuid NOT NULL UNIQUE REFERENCES submissions(id) ON DELETE CASCADE, graded_by uuid REFERENCES users(id) ON DELETE SET NULL, score numeric(10,2) NOT NULL, feedback text, graded_at timestamptz NOT NULL DEFAULT now(), CONSTRAINT chk_grade_score_nonnegative CHECK (score >= 0));"
run_sql "CREATE INDEX IF NOT EXISTS idx_grades_graded_by ON grades(graded_by);"

# ---------- Discussions ----------
run_sql "CREATE TABLE IF NOT EXISTS discussion_threads (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), course_id uuid NOT NULL REFERENCES courses(id) ON DELETE CASCADE, module_id uuid REFERENCES modules(id) ON DELETE SET NULL, title text NOT NULL, type discussion_type NOT NULL DEFAULT 'GENERAL', created_by uuid REFERENCES users(id) ON DELETE SET NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"
run_sql "CREATE INDEX IF NOT EXISTS idx_discussion_threads_course_id ON discussion_threads(course_id);"

run_sql "CREATE TABLE IF NOT EXISTS discussion_posts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), thread_id uuid NOT NULL REFERENCES discussion_threads(id) ON DELETE CASCADE, parent_post_id uuid REFERENCES discussion_posts(id) ON DELETE CASCADE, author_id uuid REFERENCES users(id) ON DELETE SET NULL, body text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"
run_sql "CREATE INDEX IF NOT EXISTS idx_discussion_posts_thread_id ON discussion_posts(thread_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_discussion_posts_parent_post_id ON discussion_posts(parent_post_id);"

# ---------- Announcements ----------
run_sql "CREATE TABLE IF NOT EXISTS announcements (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), course_id uuid NOT NULL REFERENCES courses(id) ON DELETE CASCADE, title text NOT NULL, body text NOT NULL, created_by uuid REFERENCES users(id) ON DELETE SET NULL, published_at timestamptz NOT NULL DEFAULT now());"
run_sql "CREATE INDEX IF NOT EXISTS idx_announcements_course_id ON announcements(course_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_announcements_published_at ON announcements(published_at);"

# ---------- Notifications ----------
run_sql "CREATE TABLE IF NOT EXISTS notifications (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, channel notification_channel NOT NULL DEFAULT 'IN_APP', title text NOT NULL, body text NOT NULL, link_url text, is_read boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), read_at timestamptz);"
run_sql "CREATE INDEX IF NOT EXISTS idx_notifications_user_id_created_at ON notifications(user_id, created_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS idx_notifications_is_read ON notifications(is_read);"

# ---------- Audit / logs ----------
run_sql "CREATE TABLE IF NOT EXISTS audit_logs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_user_id uuid REFERENCES users(id) ON DELETE SET NULL, action text NOT NULL, entity_type text, entity_id uuid, metadata jsonb NOT NULL DEFAULT '{}'::jsonb, ip_address text, user_agent text, created_at timestamptz NOT NULL DEFAULT now());"
run_sql "CREATE INDEX IF NOT EXISTS idx_audit_logs_actor_user_id ON audit_logs(actor_user_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON audit_logs(entity_type, entity_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at DESC);"

# ---------- Updated_at trigger (shared) ----------
run_sql "CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS \$\$ BEGIN NEW.updated_at = now(); RETURN NEW; END; \$\$ LANGUAGE plpgsql;"

run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_users_updated_at') THEN CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_courses_updated_at') THEN CREATE TRIGGER trg_courses_updated_at BEFORE UPDATE ON courses FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_modules_updated_at') THEN CREATE TRIGGER trg_modules_updated_at BEFORE UPDATE ON modules FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_content_items_updated_at') THEN CREATE TRIGGER trg_content_items_updated_at BEFORE UPDATE ON content_items FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_assignments_updated_at') THEN CREATE TRIGGER trg_assignments_updated_at BEFORE UPDATE ON assignments FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_discussion_threads_updated_at') THEN CREATE TRIGGER trg_discussion_threads_updated_at BEFORE UPDATE ON discussion_threads FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \$\$;"
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_discussion_posts_updated_at') THEN CREATE TRIGGER trg_discussion_posts_updated_at BEFORE UPDATE ON discussion_posts FOR EACH ROW EXECUTE FUNCTION set_updated_at(); END IF; END \$\$;"

# ---------- Seed data ----------
echo "Seeding baseline LMS data..."

# Roles
run_sql "INSERT INTO roles(name, description) VALUES ('ADMIN','System administrator'), ('INSTRUCTOR','Course instructor'), ('STUDENT','Learner') ON CONFLICT (name) DO NOTHING;"

# Users (password_hash is a placeholder; backend should replace with real hashed passwords)
run_sql "INSERT INTO users(email,password_hash,first_name,last_name,status) VALUES ('admin@lms.local','{noop}admin','Admin','User','ACTIVE') ON CONFLICT (email) DO NOTHING;"
run_sql "INSERT INTO users(email,password_hash,first_name,last_name,status) VALUES ('instructor@lms.local','{noop}instructor','Ina','Structor','ACTIVE') ON CONFLICT (email) DO NOTHING;"
run_sql "INSERT INTO users(email,password_hash,first_name,last_name,status) VALUES ('student@lms.local','{noop}student','Stu','Dent','ACTIVE') ON CONFLICT (email) DO NOTHING;"

# Assign roles to users
run_sql "INSERT INTO user_roles(user_id, role_id) SELECT u.id, r.id FROM users u JOIN roles r ON r.name='ADMIN' WHERE u.email='admin@lms.local' ON CONFLICT DO NOTHING;"
run_sql "INSERT INTO user_roles(user_id, role_id) SELECT u.id, r.id FROM users u JOIN roles r ON r.name='INSTRUCTOR' WHERE u.email='instructor@lms.local' ON CONFLICT DO NOTHING;"
run_sql "INSERT INTO user_roles(user_id, role_id) SELECT u.id, r.id FROM users u JOIN roles r ON r.name='STUDENT' WHERE u.email='student@lms.local' ON CONFLICT DO NOTHING;"

# Courses
run_sql "INSERT INTO courses(code,title,description,status,created_by) SELECT 'CS101','Intro to Computer Science','Foundations of CS for new learners','PUBLISHED', u.id FROM users u WHERE u.email='instructor@lms.local' ON CONFLICT (code) DO NOTHING;"
run_sql "INSERT INTO courses(code,title,description,status,created_by) SELECT 'ENG201','Professional Writing','Writing for technical and business contexts','PUBLISHED', u.id FROM users u WHERE u.email='instructor@lms.local' ON CONFLICT (code) DO NOTHING;"

# Course instructors
run_sql "INSERT INTO course_instructors(course_id,instructor_id) SELECT c.id, u.id FROM courses c JOIN users u ON u.email='instructor@lms.local' WHERE c.code='CS101' ON CONFLICT DO NOTHING;"
run_sql "INSERT INTO course_instructors(course_id,instructor_id) SELECT c.id, u.id FROM courses c JOIN users u ON u.email='instructor@lms.local' WHERE c.code='ENG201' ON CONFLICT DO NOTHING;"

# Modules (deterministic sort orders)
run_sql "INSERT INTO modules(course_id,title,description,sort_order) SELECT c.id,'Welcome','Course overview and expectations',1 FROM courses c WHERE c.code='CS101' ON CONFLICT (course_id, sort_order) DO NOTHING;"
run_sql "INSERT INTO modules(course_id,title,description,sort_order) SELECT c.id,'Basics','Core concepts and terminology',2 FROM courses c WHERE c.code='CS101' ON CONFLICT (course_id, sort_order) DO NOTHING;"

run_sql "INSERT INTO modules(course_id,title,description,sort_order) SELECT c.id,'Getting Started','Syllabus and resources',1 FROM courses c WHERE c.code='ENG201' ON CONFLICT (course_id, sort_order) DO NOTHING;"
run_sql "INSERT INTO modules(course_id,title,description,sort_order) SELECT c.id,'Writing Lab','Practice exercises',2 FROM courses c WHERE c.code='ENG201' ON CONFLICT (course_id, sort_order) DO NOTHING;"

# Content items
run_sql "INSERT INTO content_items(module_id,title,type,body,sort_order,published_at) SELECT m.id,'Read: Course Syllabus','TEXT','Welcome to the course. Review the syllabus and grading policy.',1, now() FROM modules m JOIN courses c ON c.id=m.course_id WHERE c.code='CS101' AND m.sort_order=1 ON CONFLICT (module_id, sort_order) DO NOTHING;"
run_sql "INSERT INTO content_items(module_id,title,type,url,sort_order,published_at) SELECT m.id,'Watch: What is Computer Science?','VIDEO','https://example.com/cs-intro',2, now() FROM modules m JOIN courses c ON c.id=m.course_id WHERE c.code='CS101' AND m.sort_order=1 ON CONFLICT (module_id, sort_order) DO NOTHING;"

# Enroll student
run_sql "INSERT INTO enrollments(course_id,user_id,status) SELECT c.id, u.id, 'ACTIVE' FROM courses c JOIN users u ON u.email='student@lms.local' WHERE c.code='CS101' ON CONFLICT (course_id, user_id) DO NOTHING;"

# Assignment + submission + grade (sample)
run_sql "INSERT INTO assignments(course_id,module_id,title,description,due_at,max_points,created_by) SELECT c.id, m.id, 'Assignment 1: Hello World','Submit a brief write-up explaining what a program is.', now() + interval '7 days', 100.00, instr.id FROM courses c JOIN modules m ON m.course_id=c.id AND m.sort_order=2 JOIN users instr ON instr.email='instructor@lms.local' WHERE c.code='CS101' AND NOT EXISTS (SELECT 1 FROM assignments a WHERE a.course_id=c.id AND a.title='Assignment 1: Hello World');"

run_sql "INSERT INTO submissions(assignment_id,user_id,status,submitted_at,content) SELECT a.id, u.id, 'SUBMITTED', now(), 'A program is a set of instructions a computer can execute.' FROM assignments a JOIN courses c ON c.id=a.course_id JOIN users u ON u.email='student@lms.local' WHERE c.code='CS101' AND a.title='Assignment 1: Hello World' ON CONFLICT (assignment_id, user_id) DO NOTHING;"

run_sql "INSERT INTO grades(submission_id,graded_by,score,feedback) SELECT s.id, instr.id, 95.00, 'Great explanation.' FROM submissions s JOIN users instr ON instr.email='instructor@lms.local' WHERE NOT EXISTS (SELECT 1 FROM grades g WHERE g.submission_id=s.id) AND s.status IN ('SUBMITTED','GRADED');"

# Discussion thread + post
run_sql "INSERT INTO discussion_threads(course_id,title,type,created_by) SELECT c.id, 'Introductions', 'GENERAL', instr.id FROM courses c JOIN users instr ON instr.email='instructor@lms.local' WHERE c.code='CS101' AND NOT EXISTS (SELECT 1 FROM discussion_threads t WHERE t.course_id=c.id AND t.title='Introductions');"
run_sql "INSERT INTO discussion_posts(thread_id,author_id,body) SELECT t.id, u.id, 'Hi everyone! I am excited to learn.' FROM discussion_threads t JOIN courses c ON c.id=t.course_id JOIN users u ON u.email='student@lms.local' WHERE c.code='CS101' AND t.title='Introductions' AND NOT EXISTS (SELECT 1 FROM discussion_posts p WHERE p.thread_id=t.id);"

# Announcement + notification
run_sql "INSERT INTO announcements(course_id,title,body,created_by,published_at) SELECT c.id,'Welcome to CS101','Please start by reviewing the syllabus module.', instr.id, now() FROM courses c JOIN users instr ON instr.email='instructor@lms.local' WHERE c.code='CS101' AND NOT EXISTS (SELECT 1 FROM announcements a WHERE a.course_id=c.id AND a.title='Welcome to CS101');"
run_sql "INSERT INTO notifications(user_id,channel,title,body,link_url) SELECT u.id,'IN_APP','You have been enrolled','You are enrolled in CS101. Start in the Welcome module.','/courses/CS101' FROM users u WHERE u.email='student@lms.local' AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.user_id=u.id AND n.title='You have been enrolled');"

# Audit log example
run_sql "INSERT INTO audit_logs(actor_user_id,action,entity_type,entity_id,metadata) SELECT u.id,'SEED_DATA_APPLIED','SYSTEM',NULL,'{\"source\":\"init_lms_schema_and_seed.sh\"}'::jsonb FROM users u WHERE u.email='admin@lms.local' AND NOT EXISTS (SELECT 1 FROM audit_logs al WHERE al.action='SEED_DATA_APPLIED');"

echo "✅ LMS schema + seed initialization complete."
