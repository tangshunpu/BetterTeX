# Rich LaTeX completion

Extend the existing completion popup and single-edit insertion path.

- Accept `\begin{fig`, a fully typed `\begin{figure}`, and the shorthand `\begin figure`. Offer direct environment snippets such as `\figure`, `\itemize`, and `\table` alongside commands, with descriptions in both interface languages.
- Share environment templates between argument completion and direct snippets. Figures include graphics, caption and label fields; tables include a tabular skeleton; lists include their first item. Put the caret in the first useful field. Required widths / column specifications are supplied for common environments.
- Keep explicit project macros ahead of environment shortcuts. Keep `\end` completion as a name-only edit. Preserve inline content and existing placement / arguments. Reuse matching end tags, accounting for nesting, escaped commands, comments and verbatim blocks.
- Preserve UTF-16 caret offsets, indentation and CRLF line endings. Apply each expansion as one editor edit so ordinary undo works; continue path completion when the caret lands in `\includegraphics{}`.
- Correct argument counts for useful commands such as `\textcolor`, `\captionof`, `\multicolumn`, and `\multirow`; offer ordinary and labeled `\item` forms.

Validation covers insertion text and caret positions, full-name candidates, shorthand, nested / existing endings, project macros, comments, Unicode, line endings, existing completion behavior, and interactive acceptance / undo in a temporary project.
