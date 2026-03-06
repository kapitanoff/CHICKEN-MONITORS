from fastapi import APIRouter, Depends, HTTPException, Path
from sqlalchemy.orm import Session
from pydantic import BaseModel, Field
from typing import Optional
from database import get_db
from models import Group, Chicken

router = APIRouter()


class GroupCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)


class GroupUpdate(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)


class ChickenGroupAssign(BaseModel):
    group_id: Optional[int] = None


@router.get("/groups")
def get_groups(db: Session = Depends(get_db)):
    groups = db.query(Group).order_by(Group.id).all()
    return [{"id": g.id, "name": g.name} for g in groups]


@router.post("/groups", status_code=201)
def create_group(body: GroupCreate, db: Session = Depends(get_db)):
    group = Group(name=body.name)
    db.add(group)
    db.commit()
    db.refresh(group)
    return {"id": group.id, "name": group.name}


@router.put("/groups/{group_id}")
def update_group(group_id: int, body: GroupUpdate, db: Session = Depends(get_db)):
    group = db.query(Group).filter(Group.id == group_id).first()
    if not group:
        raise HTTPException(status_code=404, detail="Group not found")
    group.name = body.name
    db.commit()
    return {"id": group.id, "name": group.name}


@router.delete("/groups/{group_id}")
def delete_group(group_id: int, db: Session = Depends(get_db)):
    group = db.query(Group).filter(Group.id == group_id).first()
    if not group:
        raise HTTPException(status_code=404, detail="Group not found")
    db.delete(group)
    db.commit()
    return {"ok": True}


@router.put("/chickens/{chicken_id}/group")
def assign_chicken_group(
    chicken_id: str = Path(..., min_length=1, max_length=32, pattern=r'^[\w\-]+$'),
    body: ChickenGroupAssign = ...,
    db: Session = Depends(get_db),
):
    chicken = db.query(Chicken).filter(Chicken.chicken_id == chicken_id).first()
    if not chicken:
        raise HTTPException(status_code=404, detail="Chicken not found")
    if body.group_id is not None:
        group = db.query(Group).filter(Group.id == body.group_id).first()
        if not group:
            raise HTTPException(status_code=404, detail="Group not found")
    chicken.group_id = body.group_id
    db.commit()
    return {"ok": True}
