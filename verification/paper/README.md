# The announcement note (`remark.pdf`)

A copy of the 4-page PDF at <https://alpo.ge/remark.pdf>, which the repository README cites as the
announcement (2026-11-20) of the claimed proof of the Riemann Hypothesis and GRH.

| | |
|---|---|
| Source | <https://alpo.ge/remark.pdf> |
| Retrieved | 2026-11-23 |
| Size / pages | 245,114 bytes, 4 pages (letter) |
| sha256 | `3fc97784b71ddd44ff8aa0a177e99622a1c61b13cfa843a0989ee4a7a0cfeb8d` |
| PDF metadata | created 2026-11-20 12:52:48 UTC by pdfTeX-1.40.29; no title, author or subject set |
| Changes | none: `remark.pdf` is the downloaded file, byte for byte |

The PDF states no licence and names no author in its text. It is kept here as a reference copy so
that the claim the Lean source is checked against stays readable if the page moves. It is a third-party
document, not part of this project's own work.

## What the note is, and is not

This is a **summary of what the 4 pages say, not an assessment of the mathematics**. Nothing in this
repository has verified the claimed proof; no result of steps 2-4 of the verification exists yet (see
[`../NOTES.md`](../NOTES.md)).

The note is a personal announcement. It contains **no theorem statement, no definition, no lemma and
no proof or proof outline that could be checked**. It says it presents only Lean
("It being obviously inappropriate to attempt to post some massive unreadable travesty of 'slop', I
decided to only present Lean"). Footnote 1 on page 1 gives the Lean source as 14 parts:
`https://alpo.ge/lean.tar.gz.part01` to `...part14`. The README at the repository root says the first
commit of this repository is that source as published.

### Claims it makes (in the author's words, paraphrased)

- A proof of the Riemann Hypothesis was found "working with Claude"; the method "easily extends" to the
  Generalized Riemann Hypothesis, and the author expects the Extended Riemann Hypothesis "with more
  time".
- The arguments were formalized in Lean "without assumptions", and the formalization "is finished".
- The argument is "incredibly long at the moment"; the author expects it to be simplified a lot and
  intends to write it up properly. A document the author says was produced along the way ran to
  "250,000+ pages" and is not posted (footnote 2, page 2).

### The idea it describes (page 1)

It describes the method as a descendant of Stepanov's argument for the Riemann Hypothesis over function
fields, which uses a divisor with multiplicity. Over the integers multiplicity is hard to find, and the
note says it is obtained from chains of theta lifts: for a von Mangoldt sum of length X, the length of
the chain of theta lifts "mimicking multiplicity" is of order the square root of X (the note shows a
square-root sign here; the PDF text extraction is garbled, so check the PDF).

### The timeline (pages 3-4)

The note gives a "rough timeline Claude provided": 20 numbered steps dated between 2026-10-06 and
2026-11-16, the last being "GRH" on 11/16/26. The steps are short, compressed fragments. The topics
named are, in order of appearance:

- a Stepanov determinant; a derivation that vanishes on a CM curve for inert primes; an identity of the
  form `qN = Mk + R` built from a sum of products of paired variables, with an interpretation through
  automorphy and Poincare bundles (footnote 3 sketches a sign argument by iterating Parseval, with
  mentions of Katz, Gabber and Bertini);
- positivity of a quantity `W(1_S) >= 0` via a determinant, with multiplicity one;
- a switch to the von Mangoldt sum, with Guinand-Weil giving the sign and a variance test-function
  trick;
- determinants for periods ("GGP periods"), iterated theta lifts between totally definite unitary
  groups that "win multiplicity m", norms and divisibility via Chowla-Selberg, Weyl and Siegel mass,
  an Iwasawa tower, a seesaw and Bessel periods (Rallis), the Bost slope inequality, a computation of
  the "cost" of each lift, a relative trace formula using a sixfold cover of GL5 and a Poincare series,
  a "significant weakening of Vandiver" for classes that twisting could not kill, covolumes and
  congruences between lifts and forms, and a choice of Iwasawa tower "using Behrend".

### Caveats the author states

- The author says they personally have "little mastery of automorphic forms on higher rank groups", and
  that the argument may have "lots of strange suboptimal choices" baked in.
- The timeline paraphrases a summary produced by Claude that "might make zero sense"; the author says
  "the Lean should suffice to clarify everything".
- The note includes remarks on the timing of the announcement and a list of acknowledgements.

### Where this leaves a reader

The note does not explain the argument; the Lean source is the only complete artifact. The
[`verification/`](..) notes describe how this repository checks the Lean.
