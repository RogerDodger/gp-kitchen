# Multi-User Dashboard Implementation Plan

## App Rename

Rename app from "flippa" to "GP Kitchen" - update branding, titles, config env var (FLIPPA_CONFIG → GP_KITCHEN_CONFIG), systemd service name, etc.

## Concepts

- **Dashboard**: User's private recipes. One per user, never shared.
- **Preset**: Admin-curated recipe collection. Browsable by all, can be imported.
- **Import Count**: Presets ranked by number of users who imported them (one count per user).

## Schema Changes

**Rename existing tables:**
- `conversions` → `recipes`
- `conversion_inputs` → `recipe_inputs`
- `conversion_outputs` → `recipe_outputs`

**New tables:**
- `users` (id, username, password_hash, is_guest, is_admin, last_active, created_at)
- `presets` (id, name, description, created_by, created_at, updated_at)
- `preset_recipes` (id, preset_id, sort_order) - no live/active flags
- `preset_recipe_inputs` (id, recipe_id, item_id, quantity)
- `preset_recipe_outputs` (id, recipe_id, item_id, quantity)
- `preset_imports` (id, preset_id, user_id, imported_at) - UNIQUE(preset_id, user_id)

**Modified tables:**
- `recipes`: Add `user_id` column

**Rename in code:**
- All routes: `/admin/conversions/*` → `/recipes/*`
- Schema.pm methods: `*_conversion_*` → `*_recipe_*`
- Templates: conversion references → recipe
- Views: `conversion_profits` → `recipe_profits`

Input/output editing (add/remove items) shares controller code and templates between user recipes and preset recipes.

## User Types

| Type | Password | Created When | Cleanup |
|------|----------|--------------|---------|
| Admin | bcrypt hash | Migration (from config.yml) | Never |
| Registered | bcrypt hash | User registers | Never |
| Guest | NULL | First dashboard action (import/create) | 30 days inactive |

Guest accounts are NOT created on page visit - only when user modifies their dashboard. This prevents web crawlers from flooding the database.

## Routes

**Auth:**
- `GET/POST /login` - Login form and handler
- `GET/POST /register` - Registration form and handler
- `GET /logout` - Clear session

**Dashboard (/):**
- `GET /` - View user's dashboard
- `POST /recipes` - Create recipe
- `GET /recipes/:id/edit` - Edit form
- `POST /recipes/:id/toggle` - Toggle active
- `POST /recipes/:id/toggle-live` - Toggle live
- `POST /recipes/:id/delete` - Delete
- `POST /recipes/reorder` - Reorder
- `POST /recipes/:id/inputs` - Add input
- `POST /recipes/:id/inputs/:input_id/delete` - Remove input
- `POST /recipes/:id/outputs` - Add output
- `POST /recipes/:id/outputs/:output_id/delete` - Remove output

**Presets (/presets):**
- `GET /presets` - Browse all (ranked by import count)
- `GET /presets/:id` - View preset (same layout as dashboard - prices, profits, etc.)
- `GET /presets/:id/import` - Import selection (simple list with inputs/outputs + checkboxes, all checked by default)
- `POST /presets/:id/import` - Import selected recipes (recipe_ids[])

**Admin (/admin):**
- `GET /admin` - Admin overview
- `POST /admin/cleanup-guests` - Run guest cleanup

**Admin Presets (/admin/presets):**
- `GET /admin/presets` - List presets
- `POST /admin/presets` - Create preset
- `GET /admin/presets/:id/edit` - Edit preset
- `POST /admin/presets/:id/delete` - Delete preset
- `POST /admin/presets/:id/recipes` - Add recipe to preset
- `GET /admin/presets/:id/recipes/:recipe_id/edit` - Edit preset recipe (shared input/output template)
- `POST /admin/presets/:id/recipes/:recipe_id/delete` - Delete recipe from preset
- Input/output routes mirror user recipe routes, share templates

## Navigation

- Dashboard (/)
- Presets (/presets)
- Admin (/admin) - admin only
- Update Prices - admin + dev mode only
- Save Account (/register) - guests only
- Login/Logout

## Migration

1. Create new tables
2. Create admin user (username: 'admin', password from config.yml, bcrypt hashed)
3. Assign all existing recipes to admin user

## Implementation Phases

**Phase 1: Database & Auth**
- Add new tables to schema.sql
- Add Crypt::Bcrypt dependency
- Create migration method
- Create helpers: current_user, is_admin, is_guest
- Update login to use users table

**Phase 2: User Dashboard**
- Scope recipe routes by user_id
- Create guest account on first dashboard action
- Move dashboard UI from /admin to /
- Update get_all_recipes to filter by user

**Phase 3: Presets**
- Create preset CRUD in Schema.pm
- Admin preset management routes and templates
- Public preset browsing routes and templates
- Import functionality with import count tracking

**Phase 4: Polish**
- Guest cleanup (30 days inactive)
- Update Prices restricted to dev mode
- Guest → Register flow
- Registration form and handler

## Dependencies

- Crypt::Bcrypt (for password hashing)

## Security

- Passwords: bcrypt with cost 12
- Authorization: Verify user_id on all recipe operations
- Presets: Admin-only creation/editing
- Guest cleanup: CASCADE delete removes all user data
