use sapling_crypto::bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
use sapling_crypto::bellman::pairing::Engine;
use sapling_crypto::bellman::{Circuit, ConstraintSystem, SynthesisError, Variable};
use sapling_crypto::circuit::{boolean, ecc, num, Assignment};

// helper for horner evaluation methods
// b = a_0 + a_1 * x
pub fn allocate_add_with_coeff<CS, E>(
    mut cs: CS,
    a1: &num::AllocatedNum<E>,
    x: &num::AllocatedNum<E>,
    a0: &num::AllocatedNum<E>,
) -> Result<num::AllocatedNum<E>, SynthesisError>
where
    E: Engine,
    CS: ConstraintSystem<E>,
{
    let ax = num::AllocatedNum::alloc(cs.namespace(|| "a1x"), || {
        let mut ax_val = *a1.get_value().get()?;
        let x_val = *x.get_value().get()?;
        ax_val.mul_assign(&x_val);
        Ok(ax_val)
    })?;

    cs.enforce(
        || "a1*x",
        |lc| lc + a1.get_variable(),
        |lc| lc + x.get_variable(),
        |lc| lc + ax.get_variable(),
    );

    let y = num::AllocatedNum::alloc(cs.namespace(|| "y"), || {
        let ax_val = *ax.get_value().get()?;
        let mut y_val = *a0.get_value().get()?;
        y_val.add_assign(&ax_val);
        Ok(y_val)
    })?;

    cs.enforce(
        || "enforce y",
        |lc| lc + ax.get_variable() + a0.get_variable(),
        |lc| lc + CS::one(),
        |lc| lc + y.get_variable(),
    );
    Ok(y)
}
