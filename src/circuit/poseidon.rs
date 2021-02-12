use crate::poseidon::{Poseidon as PoseidonHasher, PoseidonParams};
use sapling_crypto::bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
use sapling_crypto::bellman::pairing::Engine;
use sapling_crypto::bellman::{Circuit, ConstraintSystem, LinearCombination, SynthesisError};
use sapling_crypto::circuit::{boolean, ecc, num, Assignment};

#[derive(Clone)]
struct Element<E>
where
    E: Engine,
{
    an: Option<num::AllocatedNum<E>>,
    nu: Option<num::Num<E>>,
}

enum RoundType {
    Full,
    Partial,
    Exhausted,
}

struct RoundCtx<'a, E>
where
    E: Engine,
{
    number: usize,
    params: &'a PoseidonParams<E>,
}

struct State<E>
where
    E: Engine,
{
    elements: Vec<Element<E>>,
}

#[derive(Clone)]
pub struct PoseidonCircuit<E>
where
    E: Engine,
{
    params: PoseidonParams<E>,
}

impl<E> Element<E>
where
    E: Engine,
{
    pub fn new_from_alloc(an: num::AllocatedNum<E>) -> Self {
        return Element {
            an: Some(an),
            nu: None,
        };
    }

    pub fn new_from_num(nu: num::Num<E>) -> Self {
        return Element {
            an: None,
            nu: Some(nu),
        };
    }

    pub fn is_allocated(&self) -> bool {
        return self.an.is_some();
    }

    pub fn is_number(&self) -> bool {
        return self.nu.is_some();
    }

    pub fn update_with_allocated(&mut self, an: num::AllocatedNum<E>) {
        self.an = Some(an);
        self.nu = None;
    }

    pub fn update_with_num(&mut self, nu: num::Num<E>) {
        self.nu = Some(nu);
        self.an = None;
    }

    pub fn num(&self) -> num::Num<E> {
        if let Some(nu) = self.nu.clone() {
            nu
        } else {
            match self.an.clone() {
                Some(an) => num::Num::from(an),
                None => panic!("element not exist"),
            }
        }
    }

    pub fn allocate<CS: ConstraintSystem<E>>(
        &self,
        mut cs: CS,
    ) -> Result<num::AllocatedNum<E>, SynthesisError> {
        match self.nu.clone() {
            Some(nu) => {
                let v = num::AllocatedNum::alloc(cs.namespace(|| "allocate num"), || {
                    nu.get_value()
                        .ok_or_else(|| SynthesisError::AssignmentMissing)
                })?;
                cs.enforce(
                    || format!("enforce allocated"),
                    |_| nu.lc(E::Fr::one()),
                    |lc| lc + CS::one(),
                    |lc| lc + v.get_variable(),
                );
                Ok(v)
            }
            None => panic!(""),
        }
    }

    pub fn allocated(&self) -> Option<num::AllocatedNum<E>> {
        self.an.clone()
    }
}

impl<'a, E> RoundCtx<'a, E>
where
    E: Engine,
{
    pub fn new(params: &'a PoseidonParams<E>) -> Self {
        RoundCtx {
            params,
            number: 0usize,
        }
    }

    pub fn width(&self) -> usize {
        self.params.width()
    }

    pub fn round_number(&self) -> usize {
        self.number
    }

    pub fn is_full_round(&self) -> bool {
        match self.round_type() {
            RoundType::Full => true,
            _ => false,
        }
    }

    pub fn is_exhausted(&self) -> bool {
        match self.round_type() {
            RoundType::Exhausted => true,
            _ => false,
        }
    }

    pub fn is_last_round(&self) -> bool {
        self.number == self.params.total_rounds() - 1
    }

    pub fn in_transition(&self) -> bool {
        let a1 = self.params.full_round_half_len();
        let a2 = a1 + self.params.partial_round_len();
        self.number == a1 - 1 || self.number == a2 - 1
    }

    pub fn round_constant(&self) -> E::Fr {
        self.params.round_constant(self.number)
    }

    pub fn mds_matrix_row(&self, i: usize) -> Vec<E::Fr> {
        let w = self.width();
        let matrix = self.params.mds_matrix();
        matrix[i * w..(i + 1) * w].to_vec()
    }

    pub fn round_type(&self) -> RoundType {
        let a1 = self.params.full_round_half_len();
        let (a2, a3) = (
            a1 + self.params.partial_round_len(),
            self.params.total_rounds(),
        );
        if self.number < a1 {
            RoundType::Full
        } else if self.number >= a1 && self.number < a2 {
            RoundType::Partial
        } else if self.number >= a2 && self.number < a3 {
            RoundType::Full
        } else {
            RoundType::Exhausted
        }
    }

    pub fn round_end(&mut self) {
        self.number += 1;
    }
}

impl<E> State<E>
where
    E: Engine,
{
    pub fn new(elements: Vec<Element<E>>) -> Self {
        Self { elements }
    }

    pub fn first_allocated<CS: ConstraintSystem<E>>(
        &mut self,
        mut cs: CS,
    ) -> Result<num::AllocatedNum<E>, SynthesisError> {
        let el = match self.elements[0].allocated() {
            Some(an) => an,
            None => self.elements[0].allocate(cs.namespace(|| format!("alloc first")))?,
        };
        Ok(el)
    }

    fn sbox<CS: ConstraintSystem<E>>(
        &mut self,
        mut cs: CS,
        ctx: &mut RoundCtx<E>,
    ) -> Result<(), SynthesisError> {
        assert_eq!(ctx.width(), self.elements.len());

        for i in 0..if ctx.is_full_round() { ctx.width() } else { 1 } {
            let round_constant = ctx.round_constant();
            let si = {
                match self.elements[i].allocated() {
                    Some(an) => an,
                    None => self.elements[i]
                        .allocate(cs.namespace(|| format!("alloc sbox input {}", i)))?,
                }
            };
            let si2 = num::AllocatedNum::alloc(
                cs.namespace(|| format!("square with round constant {}", i)),
                || {
                    let mut val = *si.get_value().get()?;
                    val.add_assign(&round_constant);
                    val.square();
                    Ok(val)
                },
            )?;
            cs.enforce(
                || format!("constraint square with round constant {}", i),
                |lc| lc + si.get_variable() + (round_constant, CS::one()),
                |lc| lc + si.get_variable() + (round_constant, CS::one()),
                |lc| lc + si2.get_variable(),
            );
            let si4 = si2.square(cs.namespace(|| format!("si^4 {}", i)))?;
            let si5 = num::AllocatedNum::alloc(cs.namespace(|| format!("si^5 {}", i)), || {
                let mut val = *si4.get_value().get()?;
                let mut si_val = *si.get_value().get()?;
                si_val.add_assign(&round_constant);
                val.mul_assign(&si_val);
                Ok(val)
            })?;
            cs.enforce(
                || format!("constraint sbox result {}", i),
                |lc| lc + si.get_variable() + (round_constant, CS::one()),
                |lc| lc + si4.get_variable(),
                |lc| lc + si5.get_variable(),
            );
            self.elements[i].update_with_allocated(si5);
        }

        Ok(())
    }

    fn mul_mds_matrix<CS: ConstraintSystem<E>>(
        &mut self,
        ctx: &mut RoundCtx<E>,
    ) -> Result<(), SynthesisError> {
        assert_eq!(ctx.width(), self.elements.len());

        if !ctx.is_last_round() {
            // skip mds multiplication in last round

            let mut new_state: Vec<num::Num<E>> = Vec::new();
            let w = ctx.width();

            for i in 0..w {
                let row = ctx.mds_matrix_row(i);
                let mut acc = num::Num::<E>::zero();
                for j in 0..w {
                    let mut r = self.elements[j].num();
                    r.scale(row[j]);
                    acc.add_assign(&r);
                }
                new_state.push(acc);
            }

            // round ends here
            let is_full_round = ctx.is_full_round();
            let in_transition = ctx.in_transition();
            ctx.round_end();

            // add round constants just after mds if
            // first full round has just ended
            // or in partial rounds expect the last one.
            if in_transition == is_full_round {
                // add round constants for elements in {1, t}
                let round_constant = ctx.round_constant();
                for i in 1..w {
                    let mut constant_as_num = num::Num::<E>::zero();
                    constant_as_num = constant_as_num.add_bool_with_coeff(
                        CS::one(),
                        &boolean::Boolean::Constant(true),
                        round_constant,
                    );
                    new_state[i].add_assign(&constant_as_num);
                }
            }

            for (s0, s1) in self.elements.iter_mut().zip(new_state) {
                s0.update_with_num(s1);
            }
        } else {
            // terminates hades
            ctx.round_end();
        }
        Ok(())
    }
}

impl<E> PoseidonCircuit<E>
where
    E: Engine,
{
    pub fn new(params: PoseidonParams<E>) -> Self {
        Self { params: params }
    }

    pub fn width(&self) -> usize {
        self.params.width()
    }

    pub fn alloc<CS: ConstraintSystem<E>>(
        &self,
        mut cs: CS,
        input: Vec<num::AllocatedNum<E>>,
    ) -> Result<num::AllocatedNum<E>, SynthesisError> {
        assert!(input.len() < self.params.width());

        let mut elements: Vec<Element<E>> = input
            .iter()
            .map(|el| Element::new_from_alloc(el.clone()))
            .collect();
        elements.resize(self.width(), Element::new_from_num(num::Num::zero()));

        let mut state = State::new(elements);
        let mut ctx = RoundCtx::new(&self.params);
        loop {
            match ctx.round_type() {
                RoundType::Exhausted => {
                    break;
                }
                _ => {
                    let round_number = ctx.round_number();
                    state.sbox(cs.namespace(|| format!("sbox {}", round_number)), &mut ctx)?;
                    state.mul_mds_matrix::<CS>(&mut ctx)?;
                }
            }
        }
        state.first_allocated(cs.namespace(|| format!("allocate result")))
    }
}

#[test]
fn test_poseidon_circuit() {
    use sapling_crypto::bellman::pairing::bn256::{Bn256, Fr};
    use sapling_crypto::bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
    use sapling_crypto::circuit::test::TestConstraintSystem;

    let mut cs = TestConstraintSystem::<Bn256>::new();
    let params = PoseidonParams::new(8, 55, 3, None, None, None);

    let inputs: Vec<Fr> = ["0", "0"]
        .iter()
        .map(|e| Fr::from_str(e).unwrap())
        .collect();
    let allocated_inputs = inputs
        .clone()
        .into_iter()
        .enumerate()
        .map(|(i, e)| {
            let a = num::AllocatedNum::alloc(cs.namespace(|| format!("input {}", i)), || Ok(e));
            a.unwrap()
        })
        .collect();

    let circuit = PoseidonCircuit::<Bn256>::new(params.clone());
    let res_allocated = circuit
        .alloc(cs.namespace(|| "hash alloc"), allocated_inputs)
        .unwrap();
    let result = res_allocated.get_value().unwrap();
    let poseidon = PoseidonHasher::new(params.clone());
    let expected = poseidon.hash(inputs);

    assert_eq!(result, expected);
    assert!(cs.is_satisfied());
    println!(
        "number of constraints for (t: {}, rf: {}, rp: {}), {}",
        params.width(),
        params.full_round_half_len() * 2,
        params.partial_round_len(),
        cs.num_constraints()
    );
}
