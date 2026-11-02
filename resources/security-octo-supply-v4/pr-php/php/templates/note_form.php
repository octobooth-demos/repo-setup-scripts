<?php
$pageTitle = isset($data['id']) ? 'Edit Note' : 'New Note';
ob_start();
?>

<div style="margin-bottom: 1rem;">
    <a href="/notes" style="color: #0366d6; text-decoration: none; font-size: 0.9rem;">← Back to Notes</a>
</div>

<div class="card">
    <h1 style="margin-bottom: 1.5rem;"><?= isset($data['id']) ? 'Edit Note' : 'Create New Note' ?></h1>

    <?php if (!empty($errors)): ?>
        <div class="alert alert-error">
            <ul style="margin: 0; padding-left: 1.2rem;">
                <?php foreach ($errors as $err): ?>
                    <li><?= htmlspecialchars($err) ?></li>
                <?php endforeach; ?>
            </ul>
        </div>
    <?php endif; ?>

    <form method="POST" action="<?= isset($data['id']) ? "/notes/{$data['id']}/edit" : '/notes/create' ?>">
        <?php if (!isset($data['id'])): ?>
        <label for="author_name">Your Name</label>
        <input type="text" id="author_name" name="author_name" required
               value="<?= htmlspecialchars($data['author_name'] ?? '') ?>"
               placeholder="Enter your name">
        <?php endif; ?>

        <label for="title">Title</label>
        <input type="text" id="title" name="title" required maxlength="200"
               value="<?= htmlspecialchars($data['title'] ?? '') ?>"
               placeholder="Note title">

        <label for="category">Category</label>
        <select id="category" name="category">
            <?php
            $categories = ['general', 'shipping', 'quality', 'billing', 'urgent'];
            $selected = $data['category'] ?? 'general';
            foreach ($categories as $cat):
            ?>
                <option value="<?= $cat ?>" <?= $selected === $cat ? 'selected' : '' ?>>
                    <?= ucfirst($cat) ?>
                </option>
            <?php endforeach; ?>
        </select>

        <label for="content">Content</label>
        <textarea id="content" name="content" rows="10" required
                  placeholder="Write your note here... You can include details about shipping updates, quality issues, billing inquiries, etc."
                  style="font-family: inherit; resize: vertical;"><?= $data['content'] ?? '' ?></textarea>

        <div style="margin: 0.75rem 0;">
            <label style="display: inline; font-weight: normal;">
                <input type="checkbox" name="is_pinned" value="1"
                       <?= !empty($data['is_pinned']) ? 'checked' : '' ?>>
                Pin this note to the top
            </label>
        </div>

        <div style="display: flex; gap: 0.75rem; margin-top: 1rem;">
            <button type="submit" class="btn btn-primary">
                <?= isset($data['id']) ? 'Update Note' : 'Create Note' ?>
            </button>
            <a href="/notes" class="btn btn-secondary">Cancel</a>
        </div>
    </form>
</div>

<?php
$content = ob_get_clean();
require __DIR__ . '/layout.php';
?>
