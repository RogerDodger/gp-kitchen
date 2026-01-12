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
- `GET /` - View your dashboard
- `GET /recipes` - Edit your dashboard, same as current `/admin` but for this user's dashboard
- `POST /recipes` - Create recipe for your dashboard
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
- `GET /presets` - Browse all (ranked by import count), same layout as `/presets/:id` but truncated to only first three recipes, and with a header for the preset's metadata (name, import count, )
- `GET /presets/:id` - View preset (same layout as dashboard - prices, profits, etc.)
- `GET /presets/:id/import` - Import selection (same layout as `/manage` but just with checkboxes, inputs, and outputs, all checked by default)
- `POST /presets/:id/import` - Import selected recipes (recipe_ids[])

**Presets editing (admin only):**
- `GET /presets/:id/recipes` - Edit preset, same view as `/recipes`, general entry point to routes below
- `POST /presets` - New preset
- `POST /presets/:id/edit` - Edit preset - current only needed to rename it
- `POST /presets/:id/delete` - Delete preset
- `POST /presets/:id/recipes` - Add recipe to preset
- `POST /presets/:id/recipes/:id/delete` - Delete
- `POST /presets/:id/recipes/reorder` - Reorder
- `POST /presets/:id/recipes/:id/inputs` - Add input
- `POST /presets/:id/recipes/:id/inputs/:input_id/delete` - Remove input
- `POST /presets/:id/recipes/:id/outputs` - Add output
- `POST /presets/:id/recipes/:id/outputs/:output_id/delete` - Remove output
- Input/output routes mirror user recipe routes, share templates, maybe share controllers as well if reasonable

## Navigation

- Dashboard (/)
- Presets (/presets)
- Update Prices - dev mode only
- Login/Logout

- Save Account (/register) - guests only, appears as banner above header, only visible if dashboard has a recipe in it

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
