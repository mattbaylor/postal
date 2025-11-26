# Complete Rebranding Guide for Postal/Edify

This document provides comprehensive instructions for rebranding the Postal email platform to a custom brand identity. This guide is based on the "Edify" rebrand and covers all visual elements, text content, and configuration changes needed.

## Table of Contents

1. [Overview](#overview)
2. [Color Scheme](#color-scheme)
3. [Logo and Branding Assets](#logo-and-branding-assets)
4. [Text and Verbiage Changes](#text-and-verbiage-changes)
5. [Email Templates](#email-templates)
6. [Help and Documentation](#help-and-documentation)
7. [Footer and Legal](#footer-and-legal)
8. [Favicon and Icons](#favicon-and-icons)
9. [Complete Checklist](#complete-checklist)

---

## Overview

### What Gets Changed vs. What Stays the Same

**CHANGE (User-Facing):**
- Product name in UI
- Logo text
- Email templates
- Help text
- Footer attribution
- Welcome messages
- Page titles

**DO NOT CHANGE (Technical):**
- Ruby module names (`Postal::Config`)
- Method calls (`Postal.host_with_protocol`)
- Email headers (`X-Postal-*`)
- Database table names
- Configuration file structure
- Code comments

---

## Color Scheme

### Current Color Palette

The application uses SASS variables defined in:
**File:** `app/assets/stylesheets/application/global/_variables.scss`

```scss
$backgroundGrey: #fafafa;
$blue: #0e69d5;
$darkBlue: #3c4249;
$veryDarkBlue: #2b2e32;
$lightBlue: #eaf3fe;
$subBlue: #909db0;
$red: #e2383a;
$green: #76c83b;
$orange: #e8581f;
$turquoise: #4ac7c5;
$purple: #6145b2;
```

### How to Change Colors

1. **Edit the variables file:**
   ```bash
   app/assets/stylesheets/application/global/_variables.scss
   ```

2. **Key colors to customize:**
   - `$blue` - Primary action color (buttons, links)
   - `$darkBlue` - Header background, primary text
   - `$veryDarkBlue` - Darker UI elements
   - `$lightBlue` - Hover states, backgrounds
   - `$green` - Success messages
   - `$red` - Errors, danger actions
   - `$orange` - Warnings

3. **Test changes:**
   ```bash
   # Recompile assets
   bundle exec rails assets:precompile
   ```

### Recommended Workflow

1. Choose your brand colors (primary, secondary, accent)
2. Map them to existing variables
3. Update `_variables.scss`
4. Test in development mode
5. Check all UI states (buttons, alerts, forms)

---

## Logo and Branding Assets

### Logo Text (Header)

**File:** `app/views/layouts/application.html.haml`

**Line:** ~24

```haml
# BEFORE (Postal)
.siteHeader__logo= link_to "Postal", root_path

# AFTER (Your Brand)
.siteHeader__logo= link_to "YourBrand", root_path
```

### Tagline (Optional)

**File:** `app/views/layouts/application.html.haml`

**Line:** ~25

```haml
# Original (now commented out)
# %p.siteHeader__version The open source e-mail platform

# To add custom tagline:
%p.siteHeader__version Your custom tagline here
```

### Favicon

**Files to replace:**
- `app/assets/images/favicon.png` - Main favicon (used in browser tabs)
- `public/favicon.ico` - ICO format favicon
- `public/apple-touch-icon.png` - iOS home screen icon
- `public/apple-touch-icon-precomposed.png` - iOS legacy support

**Specifications:**
- `favicon.png` - 32x32px or 64x64px PNG
- `favicon.ico` - 16x16px, 32x32px, 48x48px multi-resolution ICO
- `apple-touch-icon*.png` - 180x180px PNG

**Referenced in:** `app/views/layouts/application.html.haml` (line ~8)
```haml
%link{:href => asset_path('favicon.png'), :rel => 'shortcut icon'}
```

### Logo SVG (Optional)

**File:** `app/assets/images/icon.svg`

Replace with your custom SVG logo if needed. This can be used for:
- Email headers
- Print-friendly versions
- High-resolution displays

---

## Text and Verbiage Changes

### Search Strategy

Use this command to find all user-facing references:
```bash
grep -rn "Postal" app/views --include="*.haml" --include="*.erb" \
  | grep -v "Postal::" \
  | grep -v "X-Postal" \
  | grep -v "# " \
  | grep -v "@postal" \
  | grep -v "Postal\."
```

### Primary UI Text Changes

#### 1. Login Page
**File:** `app/views/sessions/new.html.haml`

**Line:** ~2
```haml
# BEFORE
.subPageBox__title
  Welcome to Postal

# AFTER
.subPageBox__title
  Welcome to YourBrand
```

#### 2. Welcome Page
**File:** `app/views/organizations/index.html.haml`

**Line:** ~4
```haml
# BEFORE
%h1.pageHeader__title Welcome to Postal, #{current_user.first_name}

# AFTER
%h1.pageHeader__title Welcome to YourBrand, #{current_user.first_name}
```

#### 3. IP Pool Rules
**File:** `app/views/ip_pool_rules/index.html.haml`

**Lines:** ~29, ~35
```haml
# BEFORE
message that are passing through Postal. You can add rules globally

# AFTER
message that are passing through YourBrand. You can add rules globally
```

#### 4. Spam Settings
**File:** `app/views/servers/spam.html.haml`

**Line:** ~8
```haml
# BEFORE
Postal inspects all incoming messages for spam and other threats.

# AFTER
YourBrand inspects all incoming messages for spam and other threats.
```

#### 5. Tracking Domains
**File:** `app/views/track_domains/index.html.haml`

**Line:** ~14
```haml
# BEFORE
To use Postal's open & click tracking, you need to configure

# AFTER
To use YourBrand's open & click tracking, you need to configure
```

#### 6. User Creation
**File:** `app/views/users/new.html.haml`

**Line:** ~12
```haml
# BEFORE
To add someone to this Postal installation, you can add them below.

# AFTER
To add someone to this YourBrand installation, you can add them below.
```

#### 7. Webhooks History
**File:** `app/views/webhooks/history.html.haml`

**Line:** ~14
```haml
# BEFORE
webhook requests that have been sent by Postal. This page will

# AFTER
webhook requests that have been sent by YourBrand. This page will
```

#### 8. Message Activity
**File:** `app/views/messages/activity.html.haml`

**Line:** ~40
```haml
# BEFORE
Message received by Postal

# AFTER
Message received by YourBrand
```

#### 9. Server Advanced Settings
**File:** `app/views/servers/advanced.html.haml`

**Line:** ~26
```haml
# BEFORE
If enabled, when Postal adds Received headers to e-mails

# AFTER
If enabled, when YourBrand adds Received headers to e-mails
```

---

## Email Templates

All email templates are in: `app/views/app_mailer/`

### 1. Password Reset Email
**File:** `app/views/app_mailer/password_reset.text.erb`

**Lines:** 3
```erb
# BEFORE
You (or someone pretending to be you) have requested a new password for your Postal account. To choose a new password, please click the link below and you'll be able to create a new password and login to Postal.

# AFTER
You (or someone pretending to be you) have requested a new password for your YourBrand account. To choose a new password, please click the link below and you'll be able to create a new password and login to YourBrand.
```

### 2. Test Message
**File:** `app/views/app_mailer/test_message.text.erb`

**Line:** 1
```erb
# BEFORE
This is a test message sent by Postal.

# AFTER
This is a test message sent by YourBrand.
```

### 3. Domain Verification
**File:** `app/views/app_mailer/verify_domain.text.erb`

**Line:** 3
```erb
# BEFORE
would like to start sending e-mail from <%= @domain.name %> using Postal.

# AFTER
would like to start sending e-mail from <%= @domain.name %> using YourBrand.
```

### 4. Server Suspended
**File:** `app/views/app_mailer/server_suspended.text.erb`

**Line:** 3
```erb
# BEFORE
we have had to suspend one of your mail servers on Postal.

# AFTER
we have had to suspend one of your mail servers on YourBrand.
```

### 5. Send Limit Approaching
**File:** `app/views/app_mailer/server_send_limit_approaching.text.erb`

Check for any branding references (currently uses dynamic content only).

### 6. Send Limit Exceeded
**File:** `app/views/app_mailer/server_send_limit_exceeded.text.erb`

Check for any branding references (currently uses dynamic content only).

---

## Help and Documentation

### Help Pages

**File:** `app/views/help/outgoing.html.haml`

**Line:** ~60

```haml
# BEFORE
For full information about how to use our HTTP API, please #{link_to 'see the documentation', 'https://docs.postalserver.io/developer/api', :class => "u-link"}.

# AFTER (Option 1 - Remove external link)
For full information about how to use our HTTP API, please contact your system administrator.

# AFTER (Option 2 - Link to your docs)
For full information about how to use our HTTP API, please #{link_to 'see the documentation', 'https://docs.yourbrand.com/api', :class => "u-link"}.
```

### Additional Help Files

Check these files for references:
- `app/views/help/incoming.html.haml`
- `app/views/help/outgoing.html.haml`

Search command:
```bash
grep -rn "Postal\|postalserver" app/views/help/
```

---

## Footer and Legal

### Footer Attribution

**File:** `app/views/layouts/application.html.haml`

**Lines:** ~57-60

```haml
# BEFORE (Original Postal)
%li.footer__name
  Powered by
  #{link_to "Postal", "https://postalserver.io", target: '_blank'}
  #{postal_version_string}
%li= link_to "Documentation", "https://docs.postalserver.io", target: '_blank'
%li= link_to "Ask for help", "https://discussions.postalserver.io", target: '_blank'

# CURRENT (Edify - commented out)
%li.footer__name
  - # Powered by #{link_to "Postal", "https://postalserver.io", target: '_blank'} #{Postal.version}.
- # %li= link_to "Documentation", "https://docs.postalserver.io", target: '_blank'
- # %li= link_to "Ask for help", "https://discussions.postalserver.io", target: '_blank'

# OPTION 1 - No footer
(Leave commented out)

# OPTION 2 - Custom footer
%li.footer__name
  © 2024 YourCompany
%li= link_to "Documentation", "https://docs.yourcompany.com", target: '_blank'
%li= link_to "Support", "https://support.yourcompany.com", target: '_blank'
%li= link_to "Privacy Policy", "/privacy", target: '_blank'

# OPTION 3 - Acknowledge Postal (recommended for MIT license compliance)
%li.footer__name
  Powered by #{link_to "Postal", "https://postalserver.io", target: '_blank'} (customized for YourBrand)
```

### License Compliance

Postal is licensed under MIT License. You must:
1. ✓ Include MIT license text in your distribution
2. ✓ Include copyright notice
3. ✗ You do NOT need to display attribution in the UI (but it's appreciated)

**Recommendation:** Keep a `LICENSE` file in the repository acknowledging Postal's MIT license.

---

## Favicon and Icons

### Files to Replace

| File | Purpose | Recommended Size |
|------|---------|------------------|
| `app/assets/images/favicon.png` | Browser tab icon | 32x32 or 64x64 PNG |
| `public/favicon.ico` | IE/Legacy favicon | 16x16, 32x32, 48x48 ICO |
| `public/apple-touch-icon.png` | iOS home screen | 180x180 PNG |
| `public/apple-touch-icon-precomposed.png` | iOS legacy | 180x180 PNG |

### How to Create Favicons

**Option 1: Online Generator**
1. Go to https://realfavicongenerator.net/
2. Upload your logo (min 260x260px)
3. Customize for different platforms
4. Download and replace files

**Option 2: Manual Creation**
```bash
# Using ImageMagick
convert logo.png -resize 32x32 app/assets/images/favicon.png
convert logo.png -resize 180x180 public/apple-touch-icon.png
convert logo.png -define icon:auto-resize=16,32,48 public/favicon.ico
```

### Other Icons (Optional)

The application includes various SVG icons in `app/assets/images/icons/`:
- These are functional icons (email, user, search, etc.)
- Generally do NOT need rebranding
- Only change if they conflict with your brand guidelines

---

## Complete Checklist

### Pre-Rebranding

- [ ] Choose brand name
- [ ] Select color palette (primary, secondary, accent, success, error)
- [ ] Design logo (SVG preferred)
- [ ] Create favicon set (PNG, ICO)
- [ ] Decide on tagline (optional)
- [ ] Review MIT license requirements

### Color Scheme

- [ ] Update `app/assets/stylesheets/application/global/_variables.scss`
- [ ] Test primary color (`$blue`)
- [ ] Test error color (`$red`)
- [ ] Test success color (`$green`)
- [ ] Test dark backgrounds (`$darkBlue`, `$veryDarkBlue`)
- [ ] Compile assets: `bundle exec rails assets:precompile`

### Logo and Assets

- [ ] Replace `app/assets/images/favicon.png`
- [ ] Replace `public/favicon.ico`
- [ ] Replace `public/apple-touch-icon.png`
- [ ] Replace `public/apple-touch-icon-precomposed.png`
- [ ] Update logo text in header (`app/views/layouts/application.html.haml`)
- [ ] Add/update tagline (optional)

### View Templates (Main UI)

- [ ] Login page (`app/views/sessions/new.html.haml`)
- [ ] Welcome page (`app/views/organizations/index.html.haml`)
- [ ] IP Pool Rules (`app/views/ip_pool_rules/index.html.haml`) - 2 locations
- [ ] Spam settings (`app/views/servers/spam.html.haml`)
- [ ] Tracking domains (`app/views/track_domains/index.html.haml`)
- [ ] User creation (`app/views/users/new.html.haml`)
- [ ] Webhooks history (`app/views/webhooks/history.html.haml`)
- [ ] Message activity (`app/views/messages/activity.html.haml`)
- [ ] Server advanced settings (`app/views/servers/advanced.html.haml`)

### Email Templates

- [ ] Password reset (`app/views/app_mailer/password_reset.text.erb`)
- [ ] Test message (`app/views/app_mailer/test_message.text.erb`)
- [ ] Domain verification (`app/views/app_mailer/verify_domain.text.erb`)
- [ ] Server suspended (`app/views/app_mailer/server_suspended.text.erb`)
- [ ] Send limit approaching (`app/views/app_mailer/server_send_limit_approaching.text.erb`)
- [ ] Send limit exceeded (`app/views/app_mailer/server_send_limit_exceeded.text.erb`)

### Help and Documentation

- [ ] Outgoing help (`app/views/help/outgoing.html.haml`)
- [ ] Remove or update postalserver.io links
- [ ] Update or remove documentation links

### Footer

- [ ] Update footer (`app/views/layouts/application.html.haml`)
- [ ] Add custom links (support, docs, privacy)
- [ ] Consider Postal attribution (optional but appreciated)

### Testing

- [ ] Test login page
- [ ] Test dashboard/welcome page
- [ ] Send test email and verify branding
- [ ] Check all admin pages
- [ ] Verify colors across all states (hover, active, disabled)
- [ ] Test on multiple browsers
- [ ] Test on mobile devices
- [ ] Check favicon displays correctly

### Final Steps

- [ ] Commit changes with clear commit message
- [ ] Tag release: `git tag v1.0.0-yourbrand`
- [ ] Update README with your branding info
- [ ] Document any custom changes
- [ ] Keep `LICENSE` file with Postal attribution

---

## Advanced Customization

### Custom Fonts

**File:** `app/assets/stylesheets/application/global/_fonts.scss`

Add custom font imports:
```scss
@import url('https://fonts.googleapis.com/css2?family=YourFont:wght@400;600;700&display=swap');

// Then update variables
$primaryFont: 'YourFont', sans-serif;
```

### Custom Styles

Create a new file for your custom overrides:
```scss
// app/assets/stylesheets/application/custom/_brand.scss

.siteHeader__logo {
  font-weight: bold;
  font-size: 24px;
  // Add your custom styles
}
```

Import it in `app/assets/stylesheets/application/application.scss`:
```scss
@import 'custom/brand';
```

### Email Branding

For HTML email templates (if you create them):
1. Add inline styles (email clients strip external CSS)
2. Use your brand colors
3. Include logo as Base64 or hosted image
4. Keep design simple for compatibility

---

## Troubleshooting

### Colors Not Updating
```bash
# Clear cached assets
rm -rf public/assets
bundle exec rails assets:precompile
# Restart server
```

### Favicon Not Showing
- Clear browser cache (Ctrl+Shift+R or Cmd+Shift+R)
- Check file exists: `ls -la public/favicon.ico`
- Verify file isn't empty (should be >1KB)

### Finding Missed Branding
```bash
# Search all view files
grep -rn "Postal" app/views --include="*.haml" --include="*.erb" \
  | grep -v "Postal::" | grep -v "X-Postal" | grep -v "# "

# Search email templates specifically
grep -rn "Postal" app/views/app_mailer/

# Search help pages
grep -rn "postalserver\|Postal" app/views/help/
```

---

## Version Control Best Practices

### Commit Strategy

1. **Color scheme changes:**
   ```bash
   git add app/assets/stylesheets/application/global/_variables.scss
   git commit -m "feat: update color scheme for YourBrand"
   ```

2. **Logo and assets:**
   ```bash
   git add app/assets/images/ public/*.ico public/*.png
   git commit -m "feat: add YourBrand logo and favicon"
   ```

3. **Text changes:**
   ```bash
   git add app/views/
   git commit -m "chore: rebrand UI text from Postal to YourBrand"
   ```

4. **Email templates:**
   ```bash
   git add app/views/app_mailer/
   git commit -m "chore: rebrand email templates to YourBrand"
   ```

### Branch Strategy

```bash
# Create a rebranding branch
git checkout -b rebrand/yourbrand

# Make all changes
# ...

# Commit incrementally
git add <files>
git commit -m "descriptive message"

# When complete
git checkout main
git merge rebrand/yourbrand

# Tag the release
git tag v1.0.0-yourbrand
```

---

## Maintenance Notes

### Updating from Upstream Postal

If you want to pull updates from the original Postal repository:

```bash
# Add upstream remote (one time)
git remote add upstream https://github.com/postalserver/postal.git

# Fetch updates
git fetch upstream

# Review changes
git diff upstream/main

# Merge carefully (will likely have conflicts in branded files)
git merge upstream/main

# Re-apply your branding to any new/changed files
```

**Files that will likely conflict:**
- `app/views/layouts/application.html.haml`
- `app/views/sessions/new.html.haml`
- Any email templates

**Recommended approach:**
1. Keep a `REBRANDING_CHANGES.md` document listing all your modifications
2. After merging upstream, re-apply your changes manually
3. Test thoroughly

---

## Summary

This rebranding guide covers:
- ✓ Color scheme customization
- ✓ Logo and visual assets
- ✓ All user-facing text
- ✓ Email templates
- ✓ Help documentation
- ✓ Footer and attribution
- ✓ Favicon and icons

**Estimated Time:** 2-4 hours for complete rebrand

**Key Files Modified:** ~20-25 files total

**Testing Time:** 1-2 hours

Good luck with your rebrand! 🎨
