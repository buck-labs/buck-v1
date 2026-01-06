% ===== Title =====
\begin{center}
  {\Huge \textbf{CAP}}\\[-2pt]
  {\large Collateral-Aware Peg}
\end{center}

\noindent\rule{\linewidth}{0.4pt}

% ===== BUCK pricing rule =====
\begin{equation*}
{\mathrm{BUCK}}=
\begin{cases}
1.00~\text{USD}, & CR \ge 1,\\[4pt]
\max\!\bigl(P_{\mathrm{STRC}},\, CR\bigr), & CR < 1~.
\end{cases}}
\tag*{\textbf{BUCK PRICE}}
\end{equation*}

\noindent\rule{\linewidth}{0.1pt}

% ===== Collateral ratio =====
\begin{equation*}
CR=\dfrac{R + (HC \cdot V)}{L}}
\tag*{\textbf{COLLATERAL RATIO}}
\end{equation*}

\noindent\rule{\linewidth}{0.4pt}

% ===== Definitions =====
\small
\begin{aligned}
P_{\mathrm{STRC}} &:= \text{price of a 1\% slice of Stretch equity},\\
{\mathrm{BUCK}} &:= \text{price of 1 BUCK token},\\
CR &:= \text{collateral ratio},\\
R &:= \text{liquidity reserve (on-chain USDC for redemption)},\\
V &:= \text{value of all STRETCH held in the brokerage account},\\
HC &:= \text{minimal haircut for fees (e.g., }0.98\text{)},\\
L &:= \text{total outstanding liabilities or BUCK tokens minted}.
\end{aligned}
\normalsize