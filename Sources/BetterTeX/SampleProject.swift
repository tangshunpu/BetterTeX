import Foundation

enum SampleProject {
    static func create() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BetterTeX/First Paper", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sections"), withIntermediateDirectories: true)
        let files = ["main.tex": main, "sections/introduction.tex": introduction, "references.bib": bibliography, ".gitignore": ".bettertex/\n.DS_Store\n", "README.md": "# Your first paper\n\nEdit main.tex to get started. BetterTeX saves your changes and compiles automatically.\n\nCommand-click a source line or the PDF to jump between them.\n\nUse the Agent panel to launch your locally installed Codex or Claude CLI.\n"]
        for (name, text) in files { let url = base.appendingPathComponent(name); if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) } }
        return base
    }
    static let main = #"""
    % !TeX program = pdflatex
    % Welcome to BetterTeX. Make this paper yours.
    \documentclass[11pt,a4paper]{article}

    \usepackage[margin=1.05in]{geometry}
    \usepackage[T1]{fontenc}
    \usepackage{lmodern}
    \usepackage{amsmath,amssymb}
    \usepackage{xcolor}
    \usepackage[colorlinks=true,linkcolor=blue]{hyperref}

    \definecolor{ink}{HTML}{25314B}
    \definecolor{accent}{HTML}{5C80E8}
    \setlength{\parindent}{0pt}
    \setlength{\parskip}{0.7em}

    \begin{document}
    \pagestyle{plain}

    {\small\color{accent}\textsf{BETTERTEX / WORKING PAPER 001}}
    \vspace{1.2cm}

    {\Huge\color{ink}\textbf{A little less friction.\\[0.2em]
    A lot more thinking.}}

    \vspace{0.5cm}
    {\large A quiet workspace for your next idea.}

    \vspace{0.5cm}
    {\small Your name \quad / \quad \today}
    \vspace{0.6cm}
    {\color{accent}\hrule height 1pt}

    \begin{abstract}
    Good tools leave room for thought. This small document is
    a starting point: edit the source, watch the page take shape,
    and follow an idea wherever it leads.
    \end{abstract}

    \input{sections/introduction}

    \section{A simple formulation}
    Let $x$ be an idea and $f$ the work needed to express it.
    A useful workspace helps us find
    \begin{equation}
      x^{\star} = \underset{x \in \mathcal{X}}{\arg\min}
      \left[ f(x) + \lambda\,\lVert x \rVert_2^2 \right].
      \label{eq:objective}
    \end{equation}
    Equation~\ref{eq:objective} is just a beginning.
    The interesting part is what you write next.

    \section{Make it your own}
    Add a section, write a proof, or ask your agent to help
    organize the argument. Your files stay on your machine;
    your familiar tools are only a tab away.

    \vfill
    {\small\color{gray}\textsf{LOCAL TOOLS. CLEAR THINKING.}}
    \end{document}
    """#
    static let introduction = #"""
    % !TeX root = ../main.tex
    \section{Room to think}
    BetterTeX brings your source and its typeset form together.
    The editor, PDF preview, and terminal share one workspace,
    so you can stay close to both the details and the big picture.

    Command-click a line of text to find it on the page.
    Command-click the page to return to the source.
    """#
    static let bibliography = #"""
    @book{knuth1984,
      title = {The TeXbook},
      author = {Knuth, Donald E.},
      year = {1984},
      publisher = {Addison-Wesley}
    }
    """#
}
