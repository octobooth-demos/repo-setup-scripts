## Summary

Adds an internal notes system to the Supplier Portal so suppliers can document shipping issues, quality concerns, billing questions, and other internal communications tied to their account.

### Changes

- **New model**: `SupplierNote` — full CRUD with search, category filtering, and pinning support
- **New controller**: `NoteController` — handles listing, detail view, create/edit/delete, pin toggle, and search
- **New templates**: Notes listing page, detail view, and create/edit form
- **Dashboard update**: Recent notes widget on the supplier dashboard
- **Migration**: New `supplier_notes` table with foreign key to `suppliers`
- **Router/nav**: Added note routes and navigation link

### Features
- Create, edit, and delete notes
- Pin important notes to top of listing
- Filter by category (general, shipping, quality, billing, urgent)
- Full-text search across note titles and content
- Automatic excerpt generation for listing view
- Dashboard widget showing 5 most recent notes

### Testing
- Verified CRUD operations work end-to-end
- Tested category filtering and search
- Confirmed pin/unpin toggle works correctly
- Checked navigation and routing
