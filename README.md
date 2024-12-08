# milk-actions-regexp-or-gate

GitHub Action for blocking/gating a workflow on the 'OR' result of a group of jobs gathered with a regexp.

# Use case in Hardware Engineering

Sometimes we must synthesize, place, and route a design and our success rate through that process may not be 100% for a given pull request in our project. In that case, sometimes it is convenient to OR the results in case one succeeds our pipeline can continue. The designers can choose to address the issues illustrated by failing builds, and benefit from the convenience of seeing if the rest of their tests had succeeded or failed (in case of at least one success)