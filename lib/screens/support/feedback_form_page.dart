import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme.dart';

/// Dedicated homeowner feedback form. The existing ticket table and admin
/// resolution workflow remain unchanged; admin-only fields are never sent.
class FeedbackFormPage extends StatefulWidget {
  final String initialCategory;
  const FeedbackFormPage({super.key, this.initialCategory = 'problem'});

  @override
  State<FeedbackFormPage> createState() => _FeedbackFormPageState();
}

class _FeedbackFormPageState extends State<FeedbackFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _details = TextEditingController();
  late String _category = _categories.containsKey(widget.initialCategory)
      ? widget.initialCategory
      : 'problem';
  int _rating = 5;
  bool _saving = false;
  String? _submitError;

  static const _categories = <String, String>{
    'rating': 'Rate PyroGuard',
    'question': 'Ask a question',
    'problem': 'General problem',
    'bug': 'App bug',
    'device': 'Device / connection',
    'alarm': 'Buzzer / alarm',
    'account': 'Account',
    'other': 'Other',
  };

  @override
  void dispose() {
    _title.dispose();
    _details.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please log in before submitting feedback.')));
      return;
    }
    setState(() { _saving = true; _submitError = null; });
    try {
      final inserted = await Supabase.instance.client.from('support_tickets').insert({
        'user_id': user.id,
        'title': _title.text.trim(),
        'description': _category == 'rating'
            ? 'Mood rating: $_rating/5\n${_details.text.trim()}'
            : _details.text.trim(),
        'category': _category,
      }).select('id').single();
      if (inserted['id'] == null) throw StateError('No submission receipt was returned.');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Feedback submitted successfully.')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final message = e is PostgrestException
          ? (e.code == '23514'
              ? 'Supabase rejected the selected feedback type (${_categories[_category]}). Run supabase/migrations/20261030_feedback_submission_repair.sql in the PyroGuard SQL Editor.'
              : e.code == '42501' || e.code == 'PGRST301'
                  ? 'Feedback permission denied. Sign in again and verify support_tickets RLS policies.'
                  : e.code == '42P01' || e.code == 'PGRST205'
                      ? 'The support_tickets table is missing from the Supabase API.'
                      : 'Feedback was not saved: ${e.message} (${e.code ?? 'unknown code'}).')
          : 'Unable to submit feedback. Check your connection and retry. Your text is preserved.';
      setState(() { _submitError = message; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 8)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.textPrimary(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Submit Feedback')),
      body: SafeArea(child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 690),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 22, 16, 48),
          child: GlassPanel(
            radius: 22,
            padding: const EdgeInsets.all(22),
            borderColor: AppColors.orange.withValues(alpha: .28),
            child: Form(key: _formKey, child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.rate_review_outlined, color: AppColors.orange, size: 32),
                const SizedBox(height: 12),
                Text('Tell us how we can help', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
                const SizedBox(height: 7),
                Text('Your message will go to the PyroGuard support team. You can track responses under My Feedback.', style: TextStyle(color: AppTheme.textSecondary(context))),
                const SizedBox(height: 24),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Feedback type', prefixIcon: Icon(Icons.category_outlined)),
                  items: _categories.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                  onChanged: _saving ? null : (v) => setState(() { _category = v ?? 'problem'; _submitError = null; }),
                ),
                if (_category == 'rating') ...[
                  const SizedBox(height: 22),
                  Text('How was your experience?', style: TextStyle(fontWeight: FontWeight.w700, color: color)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 9, runSpacing: 9, children: [
                    for (final mood in const [(1, '😣'), (2, '😕'), (3, '😐'), (4, '😊'), (5, '😍')])
                      ChoiceChip(label: Text(mood.$2, style: const TextStyle(fontSize: 22)), selected: _rating == mood.$1, onSelected: _saving ? null : (_) => setState(() => _rating = mood.$1)),
                  ]),
                ],
                const SizedBox(height: 20),
                TextFormField(
                  controller: _title,
                  maxLength: 160,
                  decoration: const InputDecoration(labelText: 'Short title', prefixIcon: Icon(Icons.title), hintText: 'Brief summary'),
                  validator: (v) => (v ?? '').trim().length < 5 ? 'Enter at least 5 characters.' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _details,
                  maxLength: 5000,
                  minLines: 5,
                  maxLines: 8,
                  decoration: InputDecoration(
                    labelText: _category == 'rating' ? 'Your experience' : _category == 'question' ? 'Your question' : 'Describe what happened',
                    alignLabelWithHint: true,
                    hintText: 'Include helpful details, but never passwords or secret keys.',
                  ),
                  validator: (v) => (v ?? '').trim().length < 10 ? 'Enter at least 10 characters.' : null,
                ),
                const SizedBox(height: 6),
                Text('Ticket priority and resolution are managed by administrators.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary(context))),
                if (_submitError != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.red.withValues(alpha: .12),
                      border: Border.all(color: AppColors.red.withValues(alpha: .4)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SelectableText(_submitError!, style: TextStyle(color: AppTheme.textPrimary(context), height: 1.45)),
                  ),
                ],
                const SizedBox(height: 22),
                FilledButton.icon(onPressed: _saving ? null : _submit, icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send_outlined), label: Text(_saving ? 'Submitting…' : 'Submit Feedback')),
                const SizedBox(height: 8),
                TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
              ],
            )),
          ),
        ),
      ))),
    );
  }
}
