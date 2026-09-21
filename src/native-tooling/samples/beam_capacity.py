# %% [markdown]
# # Beam plastic-moment capacity — handcalcs + forallpeople
#
# Steel plastic-moment design capacity, AS 4100 / EN 1993 style. Open
# this file in JupyterLab (`jupyter lab` from `src/native-tooling/`) or
# in VS Code's Jupyter extension — jupytext round-trips the `# %%` cell
# markers to a real `.ipynb`.

# %%
%load_ext handcalcs.render
import forallpeople as si

si.environment("structural", top_level=True)

# %% [markdown]
# ## Design inputs

# %%
%%render

f_y = 355 * MPa                    # yield stress, grade 355 steel
Z_x = 1_500_000 * mm**3            # plastic section modulus, strong axis
gamma_M0 = 1.10                    # partial safety factor, resistance

# %% [markdown]
# ## Design plastic moment capacity

# %%
%%render

M_p = f_y * Z_x                    # nominal plastic moment
phi_M_p = M_p / gamma_M0           # design moment capacity

# %% [markdown]
# The `%%render` magic prints both the symbolic form and the substituted
# values with units. Same shape as a checked-and-signed calc pad, but
# the source is plain text and lives in Git.
